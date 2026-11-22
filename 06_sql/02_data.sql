\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path=tucson,pg_catalog;
SET LOCAL TIME ZONE 'America/Phoenix';
INSERT INTO person(family_name,given_name,area,email)
SELECT (ARRAY['Бат','Дорж','Сүх','Болд','Цэрэн','Даваа','Мөнх','Эрдэнэ','Ган','Цогт','Энх'])[1+(n-1)/8],
       (ARRAY['Наран','Саруул','Анужин','Тэмүүлэн','Билгүүн','Сондор','Энэрэл','Идэр'])[1+(n-1)%8],
       (ARRAY['Баянгол','Хан-Уул','Чингэлтэй','Сүхбаатар'])[1+(n-1)%4],
       format('training-%s@example.invalid',n)
FROM generate_series(1,88) n ORDER BY n;
INSERT INTO member(member_id,joined_on,intro_completed_on,discount_group)
SELECT n,date '2024-01-01',CASE WHEN n<=71 THEN date '2026-06-01' END,
       CASE WHEN n%4=0 THEN 'student' END FROM generate_series(1,72) n;
INSERT INTO member_phone SELECT member_id,(90000000+member_id)::text FROM member
UNION ALL SELECT member_id,(80000000+member_id)::text FROM member WHERE member_id%3=0;
INSERT INTO trainer(trainer_id,specialty)
SELECT n,(ARRAY['Strength','Mobility','Kettlebells','Conditioning'])[1+n%4] FROM generate_series(69,88) n;
UPDATE trainer SET substitute_trainer_id=69+(trainer_id-68)%20 WHERE trainer_id%3<>0;
WITH catalog(code,name,price,fee) AS (VALUES
 ('OPEN59','Open Gym · enrollment',59,89),('OPEN69','Open Gym · no enrollment',69,0),
 ('BASE','Base Builder',129,0),('OPTIMAL','Optimal Results',165,0),('PASS','Ten-class pass',179,0),
 ('PASS_MEMBER','Ten-class pass · Open Gym',120,0),('RESET','6-Week Strength Reset',299,0))
INSERT INTO membership_plan(product_code,plan_name,valid_from,valid_until,price_usd,enrollment_usd,bundle_min_usd,bundle_max_usd)
SELECT code,name,make_date(y,1,1),CASE WHEN y<2026 THEN make_date(y+1,1,1) END,
       price-5*(2026-y),fee,CASE WHEN code IN ('BASE','OPTIMAL') THEN 229 END,
       CASE WHEN code IN ('BASE','OPTIMAL') THEN 299 END
FROM catalog CROSS JOIN generate_series(2024,2026) y ORDER BY y,code;
WITH choices AS (
 SELECT n, CASE WHEN n<=40 THEN CASE WHEN n%2=0 THEN 'BASE' ELSE 'OPTIMAL' END
                WHEN n<=48 THEN 'OPEN59' WHEN n<=64 THEN 'OPEN69'
                WHEN n<=68 THEN 'PASS' ELSE 'RESET' END code
 FROM generate_series(1,72) n)
INSERT INTO membership_contract(member_id,plan_id,starts_on,bundle_usd,consultation_waiver)
SELECT n,plan_id,date '2026-07-01',CASE WHEN code='BASE' THEN 229 WHEN code='OPTIMAL' THEN 299 END,
       code='OPEN59' AND n=47 FROM choices JOIN membership_plan ON product_code=code AND valid_from=date '2026-01-01' ORDER BY n;
INSERT INTO membership_contract(member_id,plan_id,starts_on)
SELECT n,plan_id,date '2026-07-03' FROM generate_series(41,46) n CROSS JOIN membership_plan
WHERE product_code='PASS_MEMBER' AND valid_from=date '2026-01-01' ORDER BY n;
INSERT INTO membership_freeze(contract_id,starts_on,requested_on)
SELECT n,date '2026-07-18',date '2026-07-10' FROM generate_series(45,60) n;
DO $$
DECLARE k integer; c integer;
BEGIN
    FOR k IN 1..6 LOOP
        FOR c IN SELECT mc.contract_id FROM membership_contract mc JOIN membership_plan p USING(plan_id)
                 WHERE p.product_code IN ('BASE','OPTIMAL','OPEN59','OPEN69') ORDER BY mc.contract_id LOOP
            PERFORM renew_month(c);
        END LOOP;
    END LOOP;
END $$;
UPDATE membership_contract SET cancel_requested_on=date '2026-10-20',cancel_channel='online',access_until=date '2026-11-19'
WHERE contract_id IN (41,42,43);
DELETE FROM invoice i USING membership_contract c WHERE c.contract_id=i.contract_id AND i.cycle_index IS NOT NULL AND i.due_on>=c.access_until;
INSERT INTO invoice(contract_id,member_id,kind,due_on,subtotal_usd) VALUES(63,63,'returned','2026-10-05',10);
INSERT INTO payment(invoice_id,receipt_no,paid_on,amount_usd,method)
SELECT invoice_id,'TS-'||invoice_id,due_on,CASE WHEN member_id=62 THEN round(total_usd/2,2) ELSE total_usd END,
       (ARRAY['card','bank','cash'])[1+invoice_id%3]
FROM invoice WHERE member_id<>64 AND (member_id<>63 OR due_on<'2026-09-01') ORDER BY invoice_id;
INSERT INTO payment(invoice_id,receipt_no,paid_on,kind,amount_usd,method)
SELECT a.invoice_id,'TS-REF-'||a.invoice_id,date '2026-11-19','refund',a.refund_due,p.method
FROM invoice_position('2026-11-19') a JOIN payment p USING(invoice_id)
WHERE a.contract_id IN (41,42) AND a.refund_due>0;
INSERT INTO class_session(trainer_id,class_name,starts_at,duration_minutes,capacity)
SELECT 69+(n-1)%20,CASE WHEN n IN (1,13) THEN 'Yoga' ELSE (ARRAY['Barbell Club','Mobility','Strength Club','Kettlebells','Conditioning'])[1+(n-1)%5] END,
       ((date '2026-08-01'+(n-1)*2)+time '17:00') AT TIME ZONE 'America/Phoenix',55,8+(n-1)%7
FROM generate_series(1,70) n ORDER BY n;
DO $$
DECLARE s class_session%ROWTYPE; k integer; mid integer;
BEGIN
    FOR s IN SELECT * FROM class_session ORDER BY session_id LOOP
        FOR k IN 0..12 LOOP
            mid:=1+((CASE WHEN s.session_id IN (1,13) THEN 0 ELSE s.session_id*7 END+k)%40);
            PERFORM register_for_class(s.session_id,mid,mid,s.starts_at-interval '1 day'+k*interval '1 minute');
        END LOOP;
    END LOOP;
END $$;
UPDATE class_booking b SET cancelled_at=s.starts_at-interval '1 hour'
FROM class_session s WHERE b.session_id=s.session_id AND b.member_id%17=0 AND b.status='confirmed' AND s.session_id%3=0;
INSERT INTO attendance(session_id,member_id,attended,recorded_at)
SELECT b.session_id,b.member_id,(b.member_id+s.session_id)%9<>0,s.starts_at+s.duration_minutes*interval '1 minute'
FROM class_booking b JOIN class_session s USING(session_id)
WHERE b.status='confirmed' AND s.starts_at<'2026-11-20 00:00 America/Phoenix';
COMMIT;

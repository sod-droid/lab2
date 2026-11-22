\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path=tucson,pg_catalog;
SET LOCAL TIME ZONE 'America/Phoenix';

CREATE FUNCTION pg_temp.expect_check(label text, statement text, expected text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE statement;
        RAISE EXCEPTION 'Хязгаарлалт үйлчилсэнгүй (%).',label;
    EXCEPTION WHEN check_violation THEN
        IF position(expected in SQLERRM)=0 THEN RAISE; END IF;
        RAISE NOTICE 'PASS % [23514] %',label,SQLERRM;
    END;
END $$;

DO $$
BEGIN
    IF (SELECT count(*) FROM membership_plan WHERE valid_until IS NULL)<>7
      OR (SELECT subtotal_usd FROM invoice WHERE member_id=48 AND kind='enrollment')<>44.50
      OR EXISTS(SELECT FROM invoice WHERE member_id=47 AND kind='enrollment')
      OR (SELECT count(*) FROM invoice WHERE member_id=41 AND kind='rfid')<>1
      OR (SELECT sum(subtotal_usd) FROM invoice WHERE member_id=65 AND kind IN ('pass','intro'))<>259
      OR (SELECT total_usd FROM invoice WHERE member_id=65 AND kind='pass')<>183.65
      OR (SELECT count(*) FROM invoice WHERE member_id=1 AND kind='dues' AND cycle_index=0)<>0 THEN
       RAISE EXCEPTION 'Тарифын шалгалт амжилтгүй';
    END IF;
    IF contract_status(45,'2026-07-18')<>'frozen' OR contract_status(45,'2026-08-17')<>'active'
       OR (SELECT expires_on-base_expires_on FROM membership_contract WHERE contract_id=45)<>30
       OR billing_boundary(45,1)<>date '2026-08-31' THEN RAISE EXCEPTION 'Хугацааны шалгалт амжилтгүй'; END IF;
    IF (SELECT sum(refund_due) FROM invoice_position('2026-11-19') WHERE contract_id=43)<>24.21
       OR (SELECT sum(refund_due) FROM invoice_position('2026-11-19') WHERE contract_id=41)<>0
       OR (SELECT sum(balance) FROM invoice_position('2026-08-01') WHERE member_id=64)<>153.89 THEN
       RAISE EXCEPTION 'Буцаалт эсвэл түүхэн үлдэгдэл буруу';
    END IF;
    IF EXISTS(SELECT FROM class_session s WHERE s.confirmed_count<>(SELECT count(*) FROM class_booking b
        WHERE b.session_id=s.session_id AND b.status='confirmed') OR s.waiting_count<>(SELECT count(*)
        FROM class_booking b WHERE b.session_id=s.session_id AND b.status='waitlisted')) THEN
        RAISE EXCEPTION 'Ангийн тоолуур зөрсөн';
    END IF;
    RAISE NOTICE 'PASS catalog, tax, refund, historical balance, freeze extension and class counters';
END $$;

SELECT pg_temp.expect_check('freeze max per year',
 $$INSERT INTO membership_freeze(contract_id,starts_on,requested_on) VALUES(45,'2026-10-10','2026-10-01')$$,
 'Жилийн сургалтын хязгаар 30 хоног');
SELECT pg_temp.expect_check('online cancellation',
 $$UPDATE membership_contract SET cancel_requested_on='2026-08-01',cancel_channel='phone',access_until='2026-09-01' WHERE contract_id=44$$,
 'membership_contract');
SELECT pg_temp.expect_check('14 seats',
 $$INSERT INTO class_session(trainer_id,class_name,starts_at,duration_minutes,capacity) VALUES(69,'Yoga','2027-01-02 08:00',60,15)$$,
 'class_session_capacity_check');
DO $$
BEGIN
    BEGIN
        UPDATE active_members SET is_active=false WHERE member_id=1;
        RAISE EXCEPTION 'WITH CHECK OPTION үйлчилсэнгүй';
    EXCEPTION WHEN with_check_option_violation THEN
        RAISE NOTICE 'PASS active_members WITH CHECK OPTION [44000] %',SQLERRM;
    END;
END $$;
INSERT INTO class_session(session_id,trainer_id,class_name,starts_at,duration_minutes,capacity) OVERRIDING SYSTEM VALUE
SELECT -8000-n,69,'Mobility',(date '2027-01-03'+n)+time '09:00',60,14 FROM generate_series(1,11) n;
INSERT INTO class_session(session_id,trainer_id,class_name,starts_at,duration_minutes,capacity) OVERRIDING SYSTEM VALUE
VALUES(-8100,69,'Barbell Club','2027-01-04 17:00',60,1);
SELECT pg_temp.expect_check('Open Gym cannot book coached class',
 $$SELECT register_for_class(-8001,61,61,'2027-01-04 08:00')$$,'Ангид орох идэвхтэй багц');
INSERT INTO membership_contract(contract_id,member_id,plan_id,starts_on) OVERRIDING SYSTEM VALUE
SELECT -64,64,plan_id,'2027-01-02' FROM membership_plan WHERE product_code='PASS_MEMBER' AND valid_until IS NULL;
SELECT pg_temp.expect_check('late payments suspend access',
 $$SELECT register_for_class(-8001,64,-64,'2027-01-04 08:00')$$,'10 хоног хэтэрсэн өртэй');
DO $$
DECLARE sid integer;
BEGIN
    FOR sid IN SELECT session_id FROM class_session WHERE session_id BETWEEN -8009 AND -8001 LOOP
        PERFORM register_for_class(sid,2,2,starts_at-interval '1 hour') FROM class_session WHERE session_id=sid;
    END LOOP;
    FOR sid IN SELECT session_id FROM class_session WHERE session_id BETWEEN -8010 AND -8001 LOOP
        PERFORM register_for_class(sid,65,65,starts_at-interval '1 hour') FROM class_session WHERE session_id=sid;
    END LOOP;
    PERFORM register_for_class(-8001,1,1,'2027-01-04 08:00');
    PERFORM register_for_class(-8100,4,4,'2027-01-04 08:00');
    PERFORM register_for_class(-8100,6,6,'2027-01-04 09:00');
    PERFORM register_for_class(-8100,3,3,'2027-01-04 10:00');
    IF (SELECT member_id FROM waiting_order WHERE session_id=-8100 AND position=1)<>3 THEN
        RAISE EXCEPTION 'Optimal Results давуу эрх бүртгэгдсэнгүй';
    END IF;
    INSERT INTO class_booking(session_id,member_id,contract_id,booked_at)
    VALUES(-8100,6,6,'2027-01-04 09:00') ON CONFLICT (session_id,member_id) DO NOTHING;
    IF (SELECT waiting_count FROM class_session WHERE session_id=-8100)<>2
       OR (SELECT waitlist_number FROM register_for_class(-8100,6,6,'2027-01-04 09:00'))<>1 THEN
        RAISE EXCEPTION 'Давтан захиалга хүлээлтийн тоог өөрчилсөн';
    END IF;
    INSERT INTO class_booking(session_id,member_id,contract_id,booked_at)
    VALUES (-8100,8,8,'2027-01-04 11:00'),(-8100,10,10,'2027-01-04 12:00');
    IF (SELECT array_agg(waitlist_number ORDER BY member_id) FROM class_booking WHERE session_id=-8100 AND member_id IN (8,10))
       IS DISTINCT FROM ARRAY[3,4] THEN RAISE EXCEPTION 'Олон мөрийн дугаар давхцсан'; END IF;
    RAISE NOTICE 'PASS Optimal Results 17:00 priority, replay and bulk booking numbers';
END $$;
SELECT pg_temp.expect_check('Base Builder 10th',
 $$SELECT register_for_class(-8010,2,2,'2027-01-13 08:00')$$,'Ангийн эрхийн хязгаар дууссан');
SELECT pg_temp.expect_check('pass 11th',
 $$SELECT register_for_class(-8011,65,65,'2027-01-14 08:00')$$,'Ангийн эрхийн хязгаар дууссан');
SELECT pg_temp.expect_check('Optimal Results twice a day',
 $$SELECT register_for_class(-8100,1,1,'2027-01-04 15:00')$$,'Ангийн эрхийн хязгаар дууссан');
ROLLBACK;

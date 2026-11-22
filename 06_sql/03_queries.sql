\set ON_ERROR_STOP on
\if :{?report_date}
\else
\set report_date 2026-11-19
\endif
\if :{?mnt_per_usd}
\else
\set mnt_per_usd 3500
\endif
SET search_path=tucson,pg_catalog;
SET TIME ZONE 'America/Phoenix';

\echo '01. Хүчинтэй гэрээ'
SELECT c.contract_id,m.member_id,h.family_name,h.given_name,p.product_code,c.agreed_usd
FROM membership_contract c JOIN active_members m USING(member_id)
JOIN person h ON h.person_id=m.member_id JOIN membership_plan p USING(plan_id)
WHERE contract_status(c.contract_id,:'report_date'::date)='active' ORDER BY c.contract_id;

\echo '02. Төлбөрийн үлдэгдэл'
SELECT i.contract_id,i.member_id,h.given_name,sum(i.balance) AS due_usd
FROM invoice_position(:'report_date'::date) i JOIN person h ON h.person_id=i.member_id
GROUP BY i.contract_id,i.member_id,h.given_name HAVING sum(i.balance)>0 ORDER BY due_usd DESC,i.contract_id;

\echo '03. Ангийн багтаамж'
SELECT session_id,class_name,starts_at,capacity,confirmed_count,waiting_count,available_spots
FROM class_availability WHERE starts_at>=(:'report_date'::date-6)::timestamptz
AND starts_at<(:'report_date'::date+1)::timestamptz ORDER BY starts_at,session_id;

\echo '04. Түгээмэл таван багц'
SELECT p.product_code,count(*) AS contracts FROM membership_contract c JOIN membership_plan p USING(plan_id)
WHERE c.starts_on BETWEEN date_trunc('year',:'report_date'::date)::date AND :'report_date'::date
GROUP BY p.product_code HAVING count(*)>=5 ORDER BY contracts DESC,p.product_code LIMIT 5;

\echo '05. Сарын цэвэр орлого'
SELECT date_trunc('month',paid_on::timestamp)::date AS month_start,count(*) AS entries,
       sum(net_usd) AS net_usd,round(sum(net_usd)*:'mnt_per_usd'::numeric) AS model_mnt
FROM payment WHERE paid_on BETWEEN date_trunc('year',:'report_date'::date)::date AND :'report_date'::date
GROUP BY month_start HAVING count(*)>=5 ORDER BY month_start;

\echo '06. Дасгалжуулагчийн ирц'
SELECT t.trainer_id,h.given_name,count(DISTINCT s.session_id) AS classes,
       count(*) FILTER(WHERE a.attended) AS visits
FROM trainer t JOIN person h ON h.person_id=t.trainer_id
LEFT JOIN class_session s ON s.trainer_id=t.trainer_id
    AND s.starts_at+s.duration_minutes*interval '1 minute'<(:'report_date'::date+1)::timestamptz
LEFT JOIN attendance a ON a.session_id=s.session_id AND a.recorded_at<(:'report_date'::date+1)::timestamptz
GROUP BY t.trainer_id,h.given_name HAVING count(*) FILTER(WHERE a.attended)>=8 ORDER BY visits DESC,t.trainer_id;

\echo '07. Бүх йогийн ангид ирсэн гишүүд'
WITH yoga AS (SELECT session_id FROM class_session WHERE class_name='Yoga'
    AND starts_at::date IN (date '2026-08-01',date '2026-08-25'))
SELECT m.member_id,h.family_name,h.given_name FROM member m JOIN person h ON h.person_id=m.member_id
WHERE EXISTS(SELECT FROM yoga) AND NOT EXISTS(SELECT FROM yoga y WHERE NOT EXISTS(
    SELECT FROM attendance a WHERE a.session_id=y.session_id AND a.member_id=m.member_id AND a.attended))
ORDER BY m.member_id;

\echo '08. Захиалгагүй гишүүд'
WITH unbooked AS (SELECT member_id FROM member EXCEPT SELECT member_id FROM class_booking)
SELECT u.member_id,h.given_name FROM unbooked u JOIN person h ON h.person_id=u.member_id ORDER BY u.member_id;

\echo '09. Хувийн дунджаас өндөр төлөлт'
SELECT p.receipt_no,i.member_id,p.paid_on,p.amount_usd FROM payment p JOIN invoice i USING(invoice_id)
WHERE p.kind='payment' AND p.paid_on<=:'report_date'::date AND p.amount_usd>(
    SELECT avg(x.amount_usd) FROM payment x JOIN invoice j USING(invoice_id)
    WHERE j.member_id=i.member_id AND x.kind='payment' AND x.paid_on<=:'report_date'::date)
ORDER BY p.amount_usd DESC,p.payment_id LIMIT 15;

\echo '10. Түр зогссон хоног'
SELECT c.member_id,sum(least(f.resumes_on,:'report_date'::date+1)
    -greatest(f.starts_on,date_trunc('year',:'report_date'::date)::date)) AS days_used
FROM membership_freeze f JOIN membership_contract c USING(contract_id)
WHERE f.starts_on<=:'report_date'::date AND f.resumes_on>date_trunc('year',:'report_date'::date)::date
GROUP BY c.member_id ORDER BY days_used DESC,c.member_id;

\echo '11. Дүүргэлтийн эрэмбэ'
WITH fill AS (SELECT s.*,round(100.0*confirmed_count/capacity,1) AS pct FROM class_session s)
SELECT session_id,class_name,pct,dense_rank() OVER(PARTITION BY class_name ORDER BY pct DESC) AS rank
FROM fill ORDER BY class_name,rank,session_id;

\echo '12. Хамгийн өндөр төлөлт'
WITH r AS (SELECT i.member_id,p.receipt_no,p.amount_usd,row_number() OVER(PARTITION BY i.member_id
    ORDER BY p.amount_usd DESC,p.payment_id) AS n FROM invoice i JOIN payment p USING(invoice_id)
    WHERE p.kind='payment' AND p.paid_on<=:'report_date'::date)
SELECT member_id,receipt_no,amount_usd FROM r WHERE n=1 ORDER BY member_id;

\echo '13. Клубтэй холбоотой хүний тоо'
SELECT count(*) AS unique_people FROM (SELECT member_id FROM member UNION SELECT trainer_id FROM trainer) x;

\echo '14. Үнийн хүснэгт'
SELECT product_code,price_usd,enrollment_usd,bundle_min_usd,bundle_max_usd FROM membership_plan
WHERE :'report_date'::date <@ daterange(valid_from,valid_until,'[)') ORDER BY product_code;

\echo '15. Цуцлалтын буцаалт'
SELECT p.contract_id,p.invoice_id,c.access_until-1 AS last_access,p.credit,p.net_paid,p.refund_due
FROM invoice_position(:'report_date'::date) p JOIN membership_contract c USING(contract_id)
WHERE p.credit>0 ORDER BY p.contract_id,p.invoice_id;

\echo '16. Олон утас'
SELECT member_id,string_agg(phone,', ' ORDER BY phone) AS phones FROM member_phone
GROUP BY member_id HAVING count(*)>1 ORDER BY member_id;

\echo '17. Төлбөрийн арга'
SELECT method,count(*) AS entries,sum(net_usd) AS net_usd FROM payment WHERE paid_on<=:'report_date'::date
GROUP BY method ORDER BY net_usd DESC,method;

\echo '18. Орлох дасгалжуулагч'
SELECT t.trainer_id,h.given_name,t.specialty,t.substitute_trainer_id,r.given_name AS substitute
FROM trainer t JOIN person h ON h.person_id=t.trainer_id LEFT JOIN person r ON r.person_id=t.substitute_trainer_id
ORDER BY t.trainer_id;

\echo '19. Хоцорч цуцалсан ба тасалсан анги'
SELECT s.class_name,count(*) FILTER(WHERE b.status='late_cancelled') AS late,
       count(*) FILTER(WHERE a.attended=false) AS absent
FROM class_session s JOIN class_booking b USING(session_id) LEFT JOIN attendance a USING(session_id,member_id)
WHERE s.starts_at<(:'report_date'::date+1)::timestamptz
GROUP BY s.class_name ORDER BY s.class_name;

\echo '20. Дараагийн хүлээгч'
SELECT w.session_id,s.class_name,w.member_id,w.waitlist_number FROM waiting_order w
JOIN class_session s USING(session_id) WHERE w.position=1 ORDER BY w.session_id;

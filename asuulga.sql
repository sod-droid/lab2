\set ON_ERROR_STOP on
\pset pager off
\if :{?report_date}
\else
    \set report_date 2026-11-19
\endif
SET search_path TO fitness, public;
SET TIME ZONE 'Asia/Ulaanbaatar';

-- 01. Тайлангийн өдөр идэвхтэй гишүүний хүчинтэй гэрээ, багцыг харна.
\echo '01. Хүчинтэй гишүүнчлэл'
SELECT contract.contract_id, member.member_id, person.family_name, person.given_name,
       plan.plan_name, contract.expires_on
FROM membership_contract AS contract
JOIN member USING (member_id)
JOIN person ON person.person_id = member.member_id
JOIN membership_plan AS plan USING (plan_id)
WHERE member.is_active AND contract_status(contract.contract_id, :'report_date'::date) = 'active'
ORDER BY contract.expires_on, contract.contract_id;

-- 02. Төлбөрийн үлдэгдэл хамгийн өндөр 15 гэрээг олно.
\echo '02. Төлбөрийн үлдэгдэл'
SELECT balance.contract_id, person.given_name, balance.agreed_price_mnt,
       balance.paid_mnt, balance.balance_mnt
FROM contract_balances AS balance
JOIN person ON person.person_id = balance.member_id
WHERE balance.starts_on <= :'report_date'::date AND balance.balance_mnt > 0
ORDER BY balance.balance_mnt DESC, balance.contract_id
LIMIT 15;

-- 03. Сүүлийн долоо хоногийн анги бүрийн суудал ба хүлээлгийн хэмжээг харна.
\echo '03. Групп ангийн багтаамж'
SELECT session_id, class_name, starts_at, capacity, confirmed_count, waiting_count, available_spots
FROM class_availability
WHERE starts_at >= :'report_date'::date - INTERVAL '6 days'
  AND starts_at < :'report_date'::date + INTERVAL '1 day'
ORDER BY starts_at, session_id;

-- 04. Тухайн онд тав буюу түүнээс олон гэрээнд сонгосон шилдэг таван багцыг олно.
\echo '04. Түгээмэл таван багц'
SELECT plan.plan_id, plan.plan_name, count(*) AS contracts
FROM membership_plan AS plan
JOIN membership_contract AS contract USING (plan_id)
WHERE contract.starts_on >= date_trunc('year', :'report_date'::date::timestamp)::date
  AND contract.starts_on <= :'report_date'::date
GROUP BY plan.plan_id, plan.plan_name
HAVING count(*) >= 5
ORDER BY contracts DESC, plan.plan_id
LIMIT 5;

-- 05. Тухайн онд тав буюу түүнээс олон төлбөр авсан сарын орлогыг нэгтгэнэ.
\echo '05. Сарын орлого'
SELECT date_trunc('month', paid_on::timestamp)::date AS month_start,
       count(*) AS payments, sum(amount_mnt) AS revenue_mnt
FROM payment
WHERE paid_on >= date_trunc('year', :'report_date'::date::timestamp)::date
  AND paid_on <= :'report_date'::date
GROUP BY month_start
HAVING count(*) >= 5
ORDER BY month_start;

-- 06. Найм буюу түүнээс олон ирцтэй дасгалжуулагчийг харуулна.
\echo '06. Дасгалжуулагчийн ирцийн тайлан'
SELECT trainer.trainer_id, person.given_name,
       count(DISTINCT session.session_id) AS sessions,
       count(*) FILTER (WHERE attendance.attended) AS visits
FROM trainer
JOIN person ON person.person_id = trainer.trainer_id
LEFT JOIN class_session AS session USING (trainer_id)
LEFT JOIN attendance USING (session_id)
GROUP BY trainer.trainer_id, person.given_name
HAVING count(*) FILTER (WHERE attendance.attended) >= 8
ORDER BY visits DESC, trainer.trainer_id;

-- 07. 8-р сарын 1, 25-ны иогийн аль алинд нь ирсэн гишүүдийг олно (хуваах үйлдэл).
\echo '07. Сонгосон бүх иогийн ангид ирсэн гишүүд'
WITH selected_yoga AS (
    SELECT session_id FROM class_session
    WHERE class_name = 'Иог' AND starts_at::date IN (DATE '2026-08-01', DATE '2026-08-25')
)
SELECT member.member_id, person.family_name, person.given_name
FROM member
JOIN person ON person.person_id = member.member_id
WHERE EXISTS (SELECT 1 FROM selected_yoga)
  AND NOT EXISTS (
      SELECT 1 FROM selected_yoga AS yoga
      WHERE NOT EXISTS (
          SELECT 1 FROM attendance AS visit
          WHERE visit.session_id = yoga.session_id AND visit.member_id = member.member_id AND visit.attended
      )
  )
ORDER BY member.member_id;

-- 08. Гишүүдээс ямар ч ангид бүртгүүлээгүй хүмүүсийг EXCEPT-ээр ялгана.
\echo '08. Ангийн бүртгэлгүй гишүүд'
WITH no_bookings AS (
    SELECT member_id FROM member
    EXCEPT
    SELECT member_id FROM class_booking
)
SELECT no_bookings.member_id, person.given_name
FROM no_bookings
JOIN person ON person.person_id = no_bookings.member_id
ORDER BY no_bookings.member_id;

-- 09. Гишүүн бүрийн өөрийн дундаж төлбөрөөс их дүнтэй хамгийн өндөр 15 гүйлгээ.
\echo '09. Гишүүний дунджаас их төлбөрүүд'
SELECT payment.receipt_no, contract.member_id, payment.paid_on, payment.amount_mnt
FROM payment
JOIN membership_contract AS contract USING (contract_id)
WHERE payment.amount_mnt > (
    SELECT avg(other_payment.amount_mnt)
    FROM payment AS other_payment
    JOIN membership_contract AS other_contract USING (contract_id)
    WHERE other_contract.member_id = contract.member_id
)
ORDER BY payment.amount_mnt DESC, payment.payment_id
LIMIT 15;

-- 10. Гэрээнүүдээс хамгийн олон хоног түр зогссон 15 гэрээг харуулна.
\echo '10. Түр зогсоолтын нийт хоног'
SELECT contract.contract_id, contract.member_id, person.given_name, count(*) AS pauses,
       sum(pause.resumes_on - pause.starts_on) AS paused_days, contract.expires_on
FROM membership_contract AS contract
JOIN membership_freeze AS pause USING (contract_id)
JOIN person ON person.person_id = contract.member_id
GROUP BY contract.contract_id, person.given_name
ORDER BY paused_days DESC, contract.contract_id
LIMIT 15;

-- 11. Ангийн төрөл бүрт суудал дүүргэлтээр эхний хоёр байр эзэлсэн хичээлүүд.
\echo '11. Ангийн төрөл доторх дүүргэлтийн эрэмбэ'
WITH ranked_sessions AS (
    SELECT session_id, class_name, starts_at, confirmed_count, capacity,
           round(confirmed_count * 100.0 / capacity, 1) AS filled_percent,
           dense_rank() OVER (PARTITION BY class_name ORDER BY confirmed_count::numeric / capacity DESC) AS rank
    FROM class_availability
)
SELECT class_name, starts_at, filled_percent, rank
FROM ranked_sessions
WHERE rank <= 2
ORDER BY class_name, rank, starts_at, session_id;

-- 12. Гишүүн бүрийн хамгийн өндөр дүнтэй нэг төлбөрийг сонгоно.
\echo '12. Гишүүн бүрийн хамгийн их төлбөр'
WITH ranked_payments AS (
    SELECT contract.member_id, payment.receipt_no, payment.amount_mnt,
           row_number() OVER (
               PARTITION BY contract.member_id ORDER BY payment.amount_mnt DESC, payment.payment_id
           ) AS position
    FROM payment
    JOIN membership_contract AS contract USING (contract_id)
)
SELECT member_id, receipt_no, amount_mnt
FROM ranked_payments WHERE position = 1
ORDER BY member_id;

-- 13. Гишүүн эсвэл дасгалжуулагчийн бүртгэлтэй хүнийг давхардуулахгүй тоолно.
\echo '13. Клубтэй холбоотой нийт хүн'
SELECT count(*) AS unique_people
FROM (
    SELECT member_id AS person_id FROM member
    UNION
    SELECT trainer_id FROM trainer
) AS people;

-- 14. Ижил хугацааны борлуулалтад байгаа багцуудын дундаж үнээс хямд багцыг олно.
\echo '14. Ижил хугацааны дунджаас хямд багц'
SELECT plan_name, duration_months, price_mnt
FROM membership_plan AS plan
WHERE is_offered AND price_mnt < (
    SELECT avg(other.price_mnt) FROM membership_plan AS other
    WHERE other.duration_months = plan.duration_months AND other.is_offered
)
ORDER BY duration_months, price_mnt, plan_id;

-- 15. Хүчинтэй хугацаа дууссанаас хойш 45 хоногийн дотор сунгасан гэрээнүүд.
\echo '15. Хугацаандаа ойр сунгалт'
WITH term_history AS (
    SELECT contract_id, member_id, expires_on,
           lead(starts_on) OVER (PARTITION BY member_id ORDER BY starts_on) AS next_start
    FROM membership_contract
)
SELECT member_id, contract_id, expires_on, next_start, next_start - expires_on AS days_between
FROM term_history
WHERE next_start - expires_on BETWEEN 0 AND 45
ORDER BY days_between, member_id, contract_id
LIMIT 20;

-- 16. Хоёр буюу түүнээс олон холбоо барих дугаартай гишүүдийн туршилтын дугаарууд.
\echo '16. Гишүүний нэмэлт холбоо барих дугаар'
SELECT member_id, count(*) AS phones, string_agg(phone, ', ' ORDER BY phone) AS contact_numbers
FROM member_phone
GROUP BY member_id
HAVING count(*) >= 2
ORDER BY member_id;

-- 17. Төлбөрийн арга бүрийн тоо, дүнг сүүлийн гурван сарын хувьд нэгтгэнэ.
\echo '17. Төлбөрийн аргын тайлан'
SELECT method, count(*) AS payments, sum(amount_mnt) AS revenue_mnt
FROM payment
WHERE paid_on >= (:'report_date'::date - INTERVAL '3 months')::date
  AND paid_on <= :'report_date'::date
GROUP BY method
ORDER BY revenue_mnt DESC, method;

-- 18. Дасгалжуулагч бүрийг орлон ажиллах боломжтой дасгалжуулагчтай харуулна.
\echo '18. Орлох дасгалжуулагч'
SELECT trainer.trainer_id, person.given_name AS trainer_name, trainer.specialty,
       substitute_person.given_name AS substitute_name
FROM trainer
JOIN person ON person.person_id = trainer.trainer_id
LEFT JOIN trainer AS substitute ON substitute.trainer_id = trainer.substitute_trainer_id
LEFT JOIN person AS substitute_person ON substitute_person.person_id = substitute.trainer_id
ORDER BY trainer.trainer_id;

-- 19. Ирц бүртгэсэн ангийн төрөл тус бүрийн таслалтын хувийг олно.
\echo '19. Ангийн төрөл дэх таслалт'
SELECT session.class_name, count(*) AS attendance_records,
       count(*) FILTER (WHERE NOT attendance.attended) AS missed,
       round(100.0 * count(*) FILTER (WHERE NOT attendance.attended) / count(*), 1) AS missed_percent
FROM class_session AS session
JOIN attendance USING (session_id)
GROUP BY session.class_name
ORDER BY missed_percent DESC, session.class_name;

-- 20. Хүлээлгийн жагсаалттай анги бүрийн хамгийн эхэнд байгаа гишүүнийг харна.
\echo '20. Хүлээлгийн жагсаалтын эхний гишүүн'
SELECT DISTINCT ON (booking.session_id) booking.session_id, session.class_name, session.starts_at,
       booking.waitlist_number, person.given_name
FROM class_booking AS booking
JOIN class_session AS session USING (session_id)
JOIN person ON person.person_id = booking.member_id
WHERE booking.status = 'waitlisted'
ORDER BY booking.session_id, booking.waitlist_number;

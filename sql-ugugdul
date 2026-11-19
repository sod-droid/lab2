\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO fitness, public;
SET LOCAL TIME ZONE 'Asia/Ulaanbaatar';

INSERT INTO person (family_name, given_name, area)
SELECT
    (ARRAY['Бат', 'Дорж', 'Сүрэн', 'Цогт', 'Энх', 'Лхагва', 'Болд', 'Даваа'])[1 + (n - 1) % 8],
    (ARRAY['Анударь', 'Мөнхжин', 'Тэмүүлэн', 'Энхжин', 'Отгонбаяр', 'Билгүүн',
           'Номин', 'Мишээл', 'Амар', 'Оюун', 'Марал'])[1 + (n - 1) % 11],
    (ARRAY['Орхон, Баян-Өндөр, Зэст баг', 'Орхон, Баян-Өндөр, Хүрэнбулаг баг',
           'Орхон, Баян-Өндөр, Оюут баг', 'Орхон, Баян-Өндөр, Уурхайчин баг',
           'Орхон, Баян-Өндөр, Согоот баг'])[1 + (n - 1) % 5]
FROM generate_series(1, 62) AS seed(n)
ORDER BY n;

INSERT INTO member (member_id, joined_on, is_active)
SELECT person_id, DATE '2024-09-01' + person_id * 2, person_id % 13 <> 0
FROM person WHERE person_id BETWEEN 1 AND 48
ORDER BY person_id;

INSERT INTO member_phone (member_id, phone)
SELECT member_id, '00' || lpad(member_id::text, 6, '0') FROM member
UNION ALL
SELECT member_id, '01' || lpad(member_id::text, 6, '0') FROM member WHERE member_id <= 12;

INSERT INTO trainer (trainer_id, specialty)
SELECT person_id, (ARRAY['Иог', 'Кардио', 'Сунгалт', 'Хүчний бэлтгэл'])[1 + (person_id - 45) % 4]
FROM person WHERE person_id BETWEEN 45 AND 62
ORDER BY person_id;

UPDATE trainer SET substitute_trainer_id = CASE WHEN trainer_id = 62 THEN 45 ELSE trainer_id + 1 END;

-- Стандарт 1 ба 3 сарын багцын үнийн жишгийг нийтэд нээлттэй зарын лавлагаанаас авсан.
INSERT INTO membership_plan (plan_name, duration_months, price_mnt, is_offered)
VALUES
    ('Стандарт 1 сар', 1, 180000, true),
    ('Стандарт 3 сар', 3, 485000, true),
    ('Өглөө 1 сар', 1, 135000, true),
    ('Өглөө 3 сар', 3, 370000, true),
    ('Өдөр 1 сар', 1, 125000, true),
    ('Өдөр 3 сар', 3, 345000, true),
    ('Орой 1 сар', 1, 155000, true),
    ('Орой 3 сар', 3, 430000, true),
    ('Оюутан 1 сар', 1, 120000, true),
    ('Оюутан 3 сар', 3, 330000, true),
    ('Групп 1 сар', 1, 195000, true),
    ('Групп 3 сар', 3, 530000, true),
    ('Дасгалжуулагчтай 1 сар', 1, 240000, true),
    ('Дасгалжуулагчтай 3 сар', 3, 650000, true),
    ('Өмнөх урамшууллын багц', 1, 110000, false);

WITH terms AS (
    SELECT member.member_id, period.n,
           1 + (member.member_id + 3 * period.n - 1) % 15 AS plan_id,
           (DATE '2025-01-04' + make_interval(months => 4 * period.n))::date
               + member.member_id % 18 AS starts_on
    FROM member
    CROSS JOIN generate_series(0, 5) AS period(n)
)
INSERT INTO membership_contract (member_id, plan_id, starts_on, base_expires_on, agreed_price_mnt)
SELECT term.member_id, plan.plan_id, term.starts_on,
       (term.starts_on + make_interval(months => plan.duration_months))::date, plan.price_mnt
FROM terms AS term
JOIN membership_plan AS plan USING (plan_id)
ORDER BY term.n, term.member_id;

INSERT INTO membership_freeze (contract_id, starts_on, resumes_on, reason)
SELECT contract_id, starts_on + 6, starts_on + 11 + contract_id % 5, 'Аялал'
FROM membership_contract
WHERE contract_id % 7 = 0
UNION ALL
SELECT contract_id, starts_on + 17, starts_on + 21, 'Хувийн шалтгаан'
FROM membership_contract
WHERE contract_id % 12 = 0;

INSERT INTO payment (contract_id, receipt_no, amount_mnt, paid_on, method)
SELECT contract_id, 'ТБ-' || lpad(contract_id::text, 4, '0') || '-1',
       CASE WHEN contract_id % 7 = 0 THEN agreed_price_mnt * 2 / 3 ELSE agreed_price_mnt END,
       starts_on, (ARRAY['cash', 'card', 'qpay'])[1 + contract_id % 3]
FROM membership_contract
WHERE contract_id % 13 <> 0
UNION ALL
SELECT contract_id, 'ТБ-' || lpad(contract_id::text, 4, '0') || '-2',
       agreed_price_mnt - agreed_price_mnt * 2 / 3, starts_on + 14, 'qpay'
FROM membership_contract
WHERE contract_id % 14 = 0 AND contract_id % 13 <> 0;

INSERT INTO class_session (trainer_id, class_name, starts_at, duration_minutes, capacity)
SELECT 45 + (n - 1) % 18,
       (ARRAY['Иог', 'Кардио', 'Сунгалт', 'Хүчний бэлтгэл'])[1 + (n - 1) % 4],
       TIMESTAMPTZ '2026-08-01 08:30:00+08' + (n - 1) * INTERVAL '3 days',
       40 + (n % 3) * 10, 4 + n % 7
FROM generate_series(1, 38) AS seed(n)
ORDER BY n;

INSERT INTO class_booking (session_id, member_id, booked_at)
SELECT class.session_id, 1 + (class.session_id * 5 + applicant.n - 1) % 40,
       class.starts_at - INTERVAL '7 days' + applicant.n * INTERVAL '20 minutes'
FROM class_session AS class
CROSS JOIN LATERAL generate_series(1, 6 + class.session_id % 10) AS applicant(n)
ORDER BY class.session_id, applicant.n;

INSERT INTO attendance (session_id, member_id, attended, recorded_at)
SELECT booking.session_id, booking.member_id, (booking.session_id + booking.member_id) % 5 <> 0,
       class.starts_at + class.duration_minutes * INTERVAL '1 minute'
FROM class_booking AS booking
JOIN class_session AS class USING (session_id)
WHERE booking.status = 'confirmed' AND class.starts_at < TIMESTAMPTZ '2026-11-19 00:00:00+08';

COMMIT;
ANALYZE;

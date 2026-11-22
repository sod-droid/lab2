\set ON_ERROR_STOP on
-- Тусгай хоёр ангийг өөр ажилтай хольж устгахгүй. Давтахдаа demo_cleanup.sql ажиллуулна.
BEGIN;
SET LOCAL search_path=tucson,pg_catalog;
INSERT INTO class_session(session_id,trainer_id,class_name,starts_at,duration_minutes,capacity) OVERRIDING SYSTEM VALUE
VALUES(-7101,69,'Yoga','2026-12-24 08:00 America/Phoenix',60,2),
      (-7102,69,'Yoga','2026-12-26 08:00 America/Phoenix',60,2);
SELECT r.* FROM class_session s CROSS JOIN LATERAL register_for_class(s.session_id,1,1,s.starts_at-interval '1 day') r
WHERE s.session_id IN (-7101,-7102);
COMMIT;

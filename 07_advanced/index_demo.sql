\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path=tucson,pg_catalog;
SET LOCAL TIME ZONE 'America/Phoenix';
DROP INDEX IF EXISTS payment_paid_on_id_idx, class_session_name_starts_at_idx;
ANALYZE payment;
ANALYZE class_session;
\echo 'A. Төлбөр, индексийн өмнө'
EXPLAIN (ANALYZE,BUFFERS) SELECT receipt_no,net_usd FROM payment WHERE paid_on='2026-11-19' ORDER BY payment_id;
\echo 'B. Анги, индексийн өмнө'
EXPLAIN (ANALYZE,BUFFERS) SELECT session_id,capacity FROM class_session WHERE class_name='Yoga' AND starts_at>='2026-08-01' AND starts_at<'2026-08-02';
\ir indexes.sql
\echo 'A. Төлбөр, индексийн дараа'
EXPLAIN (ANALYZE,BUFFERS) SELECT receipt_no,net_usd FROM payment WHERE paid_on='2026-11-19' ORDER BY payment_id;
\echo 'B. Анги, индексийн дараа'
EXPLAIN (ANALYZE,BUFFERS) SELECT session_id,capacity FROM class_session WHERE class_name='Yoga' AND starts_at>='2026-08-01' AND starts_at<'2026-08-02';
ROLLBACK;

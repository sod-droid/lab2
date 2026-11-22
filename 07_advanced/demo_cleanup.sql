\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path=tucson,pg_catalog;
DELETE FROM class_booking WHERE session_id IN (-7101,-7102);
DELETE FROM class_session WHERE session_id IN (-7101,-7102);
COMMIT;

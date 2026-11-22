SET search_path=tucson,pg_catalog;
CREATE INDEX IF NOT EXISTS payment_paid_on_id_idx ON payment(paid_on,payment_id);
CREATE INDEX IF NOT EXISTS class_session_name_starts_at_idx ON class_session(class_name,starts_at);
ANALYZE payment;
ANALYZE class_session;

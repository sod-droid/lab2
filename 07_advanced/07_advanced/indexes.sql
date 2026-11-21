\set ON_ERROR_STOP on
CREATE INDEX IF NOT EXISTS payment_paid_on_id_idx
    ON fitness.payment (paid_on, payment_id);
CREATE INDEX IF NOT EXISTS class_session_name_starts_at_idx
    ON fitness.class_session (class_name, starts_at);

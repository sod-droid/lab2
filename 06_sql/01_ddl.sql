\set ON_ERROR_STOP on
BEGIN;
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;
CREATE SCHEMA tucson;
SET LOCAL search_path = tucson, public;
CREATE TABLE person (
    person_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    family_name text NOT NULL CHECK (btrim(family_name) <> ''),
    given_name text NOT NULL CHECK (btrim(given_name) <> ''),
    area text NOT NULL CHECK (btrim(area) <> ''),
    email text NOT NULL UNIQUE CHECK (position('@' in email) > 1)
);
CREATE TABLE member (
    member_id integer PRIMARY KEY REFERENCES person ON DELETE CASCADE,
    joined_on date NOT NULL DEFAULT CURRENT_DATE,
    is_active boolean NOT NULL DEFAULT true,
    intro_completed_on date,
    discount_group text CHECK (discount_group IN ('military','responder','student','neighbor'))
);
CREATE TABLE member_phone (
    member_id integer REFERENCES member ON DELETE CASCADE,
    phone text CHECK (phone ~ '^([0-9]{8}|[+][1-9][0-9]{7,14})$'),
    PRIMARY KEY (member_id, phone)
);
CREATE TABLE trainer (
    trainer_id integer PRIMARY KEY REFERENCES person ON DELETE CASCADE,
    specialty text NOT NULL CHECK (btrim(specialty) <> ''),
    substitute_trainer_id integer REFERENCES trainer ON DELETE SET NULL,
    CHECK (trainer_id <> substitute_trainer_id)
);
CREATE TABLE membership_plan (
    plan_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_code text NOT NULL CHECK (product_code IN ('OPEN59','OPEN69','BASE','OPTIMAL','PASS','PASS_MEMBER','RESET')),
    plan_name text NOT NULL CHECK (btrim(plan_name) <> ''),
    valid_from date NOT NULL,
    valid_until date CHECK (valid_until > valid_from),
    price_usd numeric(9,2) NOT NULL CHECK (price_usd > 0),
    enrollment_usd numeric(9,2) NOT NULL DEFAULT 0 CHECK (enrollment_usd >= 0),
    bundle_min_usd numeric(9,2),
    bundle_max_usd numeric(9,2),
    CHECK ((bundle_min_usd IS NOT NULL) = (product_code IN ('BASE','OPTIMAL'))),
    CHECK ((bundle_max_usd IS NOT NULL) = (bundle_min_usd IS NOT NULL)),
    CHECK (bundle_min_usd >= price_usd AND bundle_max_usd >= bundle_min_usd),
    UNIQUE (product_code, valid_from),
    EXCLUDE USING gist (product_code WITH =, daterange(valid_from, valid_until,'[)') WITH &&)
);
CREATE TABLE membership_contract (
    contract_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    member_id integer NOT NULL REFERENCES member ON DELETE RESTRICT,
    plan_id integer NOT NULL REFERENCES membership_plan ON DELETE RESTRICT,
    starts_on date NOT NULL CHECK (isfinite(starts_on)),
    agreed_usd numeric(9,2) NOT NULL CHECK (agreed_usd > 0),
    bundle_usd numeric(9,2),
    consultation_waiver boolean NOT NULL DEFAULT false,
    periods integer NOT NULL DEFAULT 1 CHECK (periods >= 1),
    base_expires_on date CHECK (base_expires_on > starts_on),
    frozen_days integer NOT NULL DEFAULT 0 CHECK (frozen_days >= 0),
    expires_on date GENERATED ALWAYS AS (base_expires_on + frozen_days) STORED,
    cancel_requested_on date,
    cancel_channel text,
    access_until date,
    CHECK ((cancel_requested_on IS NULL AND cancel_channel IS NULL AND access_until IS NULL)
        OR (cancel_requested_on IS NOT NULL AND cancel_channel IS NOT NULL AND cancel_channel = 'online'
            AND access_until IS NOT NULL AND cancel_requested_on >= starts_on
            AND access_until >= cancel_requested_on + 30)),
    UNIQUE (contract_id, member_id),
    UNIQUE (member_id, plan_id, starts_on)
);
CREATE TABLE membership_freeze (
    contract_id integer REFERENCES membership_contract ON DELETE RESTRICT,
    starts_on date,
    requested_on date NOT NULL,
    resumes_on date GENERATED ALWAYS AS (starts_on + 30) STORED,
    PRIMARY KEY (contract_id, starts_on),
    CHECK (isfinite(starts_on) AND isfinite(requested_on) AND requested_on <= starts_on - 7),
    EXCLUDE USING gist (contract_id WITH =, daterange(starts_on, starts_on + 30,'[)') WITH &&)
);
CREATE TABLE invoice (
    invoice_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contract_id integer NOT NULL,
    member_id integer NOT NULL,
    kind text NOT NULL CHECK (kind IN ('dues','bundle','enrollment','pass','reset','intro','rfid','freeze','returned')),
    due_on date NOT NULL,
    cycle_index integer CHECK (cycle_index >= 0),
    coverage_end date CHECK (coverage_end > due_on),
    subtotal_usd numeric(10,2) NOT NULL CHECK (subtotal_usd > 0),
    tax_usd numeric(10,2) GENERATED ALWAYS AS (round(subtotal_usd * 0.026, 2)) STORED,
    total_usd numeric(10,2) GENERATED ALWAYS AS (subtotal_usd + round(subtotal_usd * 0.026,2)) STORED,
    FOREIGN KEY (contract_id,member_id) REFERENCES membership_contract(contract_id,member_id) ON DELETE RESTRICT,
    CHECK ((kind IN ('dues','bundle')) = (coverage_end IS NOT NULL)),
    CHECK ((kind IN ('dues','bundle')) = (cycle_index IS NOT NULL)),
    CHECK (kind <> 'rfid' OR subtotal_usd = 12),
    CHECK (kind <> 'freeze' OR subtotal_usd = 15),
    CHECK (kind <> 'returned' OR subtotal_usd = 10),
    CHECK (kind <> 'intro' OR subtotal_usd = 80)
);
CREATE UNIQUE INDEX one_rfid_per_member ON invoice(member_id) WHERE kind='rfid';
CREATE UNIQUE INDEX one_charge_per_date ON invoice(contract_id, kind, due_on) WHERE kind NOT IN ('dues','bundle','returned');
CREATE UNIQUE INDEX one_recurring_cycle ON invoice(contract_id,cycle_index) WHERE cycle_index IS NOT NULL;
CREATE TABLE payment (
    payment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id integer NOT NULL REFERENCES invoice ON DELETE RESTRICT,
    receipt_no text NOT NULL UNIQUE CHECK (btrim(receipt_no) <> ''),
    paid_on date NOT NULL DEFAULT CURRENT_DATE,
    kind text NOT NULL DEFAULT 'payment' CHECK (kind IN ('payment','refund')),
    amount_usd numeric(10,2) NOT NULL CHECK (amount_usd > 0),
    method text NOT NULL CHECK (method IN ('card','bank','cash')),
    net_usd numeric(10,2) GENERATED ALWAYS AS (CASE WHEN kind='refund' THEN -amount_usd ELSE amount_usd END) STORED
);
CREATE TABLE class_session (
    session_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trainer_id integer NOT NULL REFERENCES trainer ON DELETE RESTRICT,
    class_name text NOT NULL CHECK (btrim(class_name) <> ''),
    starts_at timestamptz NOT NULL,
    duration_minutes smallint NOT NULL CHECK (duration_minutes > 0),
    capacity smallint NOT NULL DEFAULT 14 CHECK (capacity BETWEEN 1 AND 14),
    confirmed_count smallint NOT NULL DEFAULT 0 CHECK (confirmed_count BETWEEN 0 AND capacity),
    waiting_count integer NOT NULL DEFAULT 0 CHECK (waiting_count >= 0),
    last_waitlist_number integer NOT NULL DEFAULT 0 CHECK (last_waitlist_number >= waiting_count),
    UNIQUE (trainer_id, starts_at)
);
CREATE TABLE class_booking (
    session_id integer REFERENCES class_session ON DELETE RESTRICT,
    member_id integer,
    contract_id integer NOT NULL,
    booked_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status text NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed','waitlisted','cancelled','late_cancelled')),
    waitlist_number integer CHECK (waitlist_number > 0),
    cancelled_at timestamptz,
    PRIMARY KEY (session_id,member_id),
    FOREIGN KEY (contract_id,member_id) REFERENCES membership_contract(contract_id,member_id) ON DELETE RESTRICT,
    UNIQUE (session_id,waitlist_number),
    UNIQUE (session_id,member_id,status),
    CHECK ((status='waitlisted') = (waitlist_number IS NOT NULL)),
    CHECK ((status IN ('cancelled','late_cancelled')) = (cancelled_at IS NOT NULL)),
    CHECK (cancelled_at >= booked_at)
);
CREATE TABLE attendance (
    session_id integer,
    member_id integer,
    attended boolean NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    booking_status text GENERATED ALWAYS AS ('confirmed'::text) STORED,
    PRIMARY KEY (session_id,member_id),
    FOREIGN KEY (session_id,member_id,booking_status)
        REFERENCES class_booking(session_id,member_id,status) ON DELETE RESTRICT
);
COMMIT;

\set ON_ERROR_STOP on

BEGIN;
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;
CREATE SCHEMA fitness;
SET LOCAL search_path TO fitness, public;

CREATE TABLE person (
    person_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    family_name text NOT NULL CHECK (btrim(family_name) <> ''),
    given_name text NOT NULL CHECK (btrim(given_name) <> ''),
    area text NOT NULL CHECK (btrim(area) <> '')
);

CREATE TABLE member (
    member_id integer PRIMARY KEY REFERENCES person (person_id) ON DELETE CASCADE,
    joined_on date NOT NULL DEFAULT CURRENT_DATE,
    is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE member_phone (
    member_id integer REFERENCES member (member_id) ON DELETE CASCADE,
    phone text CHECK (phone ~ '^[0-9]{8}$'),
    PRIMARY KEY (member_id, phone)
);

CREATE TABLE trainer (
    trainer_id integer PRIMARY KEY REFERENCES person (person_id) ON DELETE CASCADE,
    specialty text NOT NULL CHECK (btrim(specialty) <> ''),
    substitute_trainer_id integer REFERENCES trainer (trainer_id) ON DELETE SET NULL,
    CHECK (substitute_trainer_id <> trainer_id)
);

CREATE TABLE membership_plan (
    plan_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_name text NOT NULL UNIQUE CHECK (btrim(plan_name) <> ''),
    duration_months smallint NOT NULL CHECK (duration_months > 0),
    price_mnt integer NOT NULL CHECK (price_mnt > 0),
    is_offered boolean NOT NULL DEFAULT true
);

CREATE TABLE membership_contract (
    contract_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    member_id integer NOT NULL REFERENCES member (member_id) ON DELETE RESTRICT,
    plan_id integer NOT NULL REFERENCES membership_plan (plan_id) ON DELETE RESTRICT,
    starts_on date NOT NULL CHECK (isfinite(starts_on)),
    base_expires_on date NOT NULL CHECK (isfinite(base_expires_on)),
    agreed_price_mnt integer NOT NULL CHECK (agreed_price_mnt > 0),
    frozen_days integer NOT NULL DEFAULT 0 CHECK (frozen_days >= 0),
    expires_on date GENERATED ALWAYS AS (base_expires_on + frozen_days) STORED,
    CONSTRAINT contract_dates_ordered CHECK (starts_on < base_expires_on),
    UNIQUE (member_id, starts_on)
);

CREATE TABLE membership_freeze (
    contract_id integer REFERENCES membership_contract (contract_id) ON DELETE RESTRICT,
    starts_on date CHECK (isfinite(starts_on)),
    resumes_on date NOT NULL CHECK (isfinite(resumes_on)),
    reason text,
    PRIMARY KEY (contract_id, starts_on),
    CONSTRAINT freeze_duration_valid CHECK (resumes_on - starts_on BETWEEN 1 AND 60),
    CONSTRAINT freeze_periods_disjoint EXCLUDE USING gist (
        contract_id WITH =,
        daterange(starts_on, resumes_on, '[)') WITH &&
    )
);

CREATE TABLE payment (
    payment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contract_id integer NOT NULL REFERENCES membership_contract (contract_id) ON DELETE RESTRICT,
    receipt_no text NOT NULL UNIQUE CHECK (btrim(receipt_no) <> ''),
    amount_mnt integer NOT NULL CHECK (amount_mnt > 0),
    paid_on date NOT NULL DEFAULT CURRENT_DATE,
    method text NOT NULL CHECK (method IN ('cash', 'card', 'qpay'))
);

CREATE TABLE class_session (
    session_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trainer_id integer NOT NULL REFERENCES trainer (trainer_id) ON DELETE RESTRICT,
    class_name text NOT NULL CHECK (btrim(class_name) <> ''),
    starts_at timestamptz NOT NULL,
    duration_minutes smallint NOT NULL CHECK (duration_minutes > 0),
    capacity smallint NOT NULL CHECK (capacity > 0),
    confirmed_count smallint NOT NULL DEFAULT 0,
    waiting_count integer NOT NULL DEFAULT 0,
    last_waitlist_number integer NOT NULL DEFAULT 0,
    CONSTRAINT session_seat_limit CHECK (confirmed_count BETWEEN 0 AND capacity),
    CONSTRAINT session_waitlist_count_valid CHECK (waiting_count BETWEEN 0 AND last_waitlist_number),
    UNIQUE (trainer_id, starts_at)
);

CREATE TABLE class_booking (
    session_id integer REFERENCES class_session (session_id) ON DELETE RESTRICT,
    member_id integer REFERENCES member (member_id) ON DELETE RESTRICT,
    booked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    waitlist_number integer CHECK (waitlist_number > 0),
    status text GENERATED ALWAYS AS (
        CASE WHEN waitlist_number IS NULL THEN 'confirmed' ELSE 'waitlisted' END
    ) STORED,
    PRIMARY KEY (session_id, member_id),
    UNIQUE (session_id, waitlist_number),
    UNIQUE (session_id, member_id, status)
);

CREATE TABLE attendance (
    session_id integer,
    member_id integer,
    attended boolean NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    booking_status text GENERATED ALWAYS AS ('confirmed'::text) STORED,
    PRIMARY KEY (session_id, member_id),
    FOREIGN KEY (session_id, member_id, booking_status)
        REFERENCES class_booking (session_id, member_id, status) ON DELETE RESTRICT
);

COMMIT;

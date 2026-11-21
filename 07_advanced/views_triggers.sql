-- Codex reference implementation. Sample records are synthetic.
-- Хоёр онцгой дүрэм, тайлангийн view болон ажилтны функц.
\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path TO fitness, public;

CREATE FUNCTION maintain_membership_freeze() RETURNS trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog, fitness
AS $$
DECLARE
    target_contract_id integer;
    day_change integer;
    contract_start date;
    base_expiry date;
BEGIN
    CASE TG_OP
        WHEN 'INSERT' THEN
            target_contract_id := NEW.contract_id;
            day_change := NEW.resumes_on - NEW.starts_on;
        WHEN 'UPDATE' THEN
            IF NEW.contract_id <> OLD.contract_id THEN
                RAISE EXCEPTION 'Түр зогсоолтын гэрээг солих боломжгүй'
                    USING ERRCODE = '23514';
            END IF;
            target_contract_id := NEW.contract_id;
            day_change := (NEW.resumes_on - NEW.starts_on) - (OLD.resumes_on - OLD.starts_on);
        WHEN 'DELETE' THEN
            target_contract_id := OLD.contract_id;
            day_change := -(OLD.resumes_on - OLD.starts_on);
    END CASE;

    -- Нэг гэрээний өөрчлөлтүүд ижил мөрийг шинэчилж, зэрэг тооцоолохоос сэргийлнэ.
    UPDATE membership_contract
    SET frozen_days = frozen_days + day_change
    WHERE contract_id = target_contract_id
    RETURNING starts_on, base_expires_on INTO contract_start, base_expiry;

    -- Шинэ жил дамнасан түр зогсоолтын хоногийг тухайн хуанлийн жилд тооцно.
    IF EXISTS (
        SELECT 1
        FROM membership_freeze AS pause
        CROSS JOIN LATERAL generate_series(0, pause.resumes_on - pause.starts_on - 1)
            AS calendar_day(day_offset)
        WHERE pause.contract_id = target_contract_id
        GROUP BY EXTRACT(YEAR FROM (pause.starts_on + calendar_day.day_offset))
        HAVING count(*) > 30
    ) THEN
        RAISE EXCEPTION 'Гэрээ % нэг хуанлийн жилд 30 хоногоос илүү түр зогсох боломжгүй',
            target_contract_id USING ERRCODE = '23514';
    END IF;

    -- Эхлэх өдөр нь өмнөх зогсоолтоор сунгагдсан хүчинтэй хугацаанд багтана.
    IF EXISTS (
        SELECT 1
        FROM (
            SELECT starts_on, sum(resumes_on - starts_on) OVER (
                ORDER BY starts_on ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS prior_days
            FROM membership_freeze
            WHERE contract_id = target_contract_id
        ) AS timeline
        WHERE timeline.starts_on < contract_start
           OR timeline.starts_on >= base_expiry + coalesce(timeline.prior_days, 0)::integer
    ) THEN
        RAISE EXCEPTION 'Түр зогсоолт гэрээ % хүчинтэй байх үед эхлэх ёстой',
            target_contract_id USING ERRCODE = '23514';
    END IF;

    RETURN NULL;
END;
$$;

CREATE TRIGGER membership_freeze_changes
AFTER INSERT OR UPDATE OR DELETE ON membership_freeze
FOR EACH ROW EXECUTE FUNCTION maintain_membership_freeze();

CREATE FUNCTION maintain_class_booking() RETURNS trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog, fitness
AS $$
DECLARE
    target_session_id integer := CASE WHEN TG_OP = 'DELETE' THEN OLD.session_id ELSE NEW.session_id END;
    session_row class_session%ROWTYPE;
BEGIN
    IF TG_OP = 'UPDATE' AND (NEW.session_id, NEW.member_id) IS DISTINCT FROM (OLD.session_id, OLD.member_id) THEN
        RAISE EXCEPTION 'Бүртгэлийн анги, гишүүний дугаарыг солих боломжгүй'
            USING ERRCODE = '23514';
    END IF;

    -- Ангийн мөрийг түгжиж, суудал олгох ба дугаар өгөх шийдвэрийг дарааллаар гаргана.
    SELECT * INTO session_row
    FROM class_session
    WHERE session_id = target_session_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Анги % олдсонгүй', target_session_id USING ERRCODE = '23503';
    END IF;

    IF TG_OP = 'INSERT' THEN
        SELECT booking.waitlist_number INTO NEW.waitlist_number
        FROM class_booking AS booking
        WHERE booking.session_id = target_session_id AND booking.member_id = NEW.member_id;
        IF FOUND THEN
            -- ON CONFLICT давтан хүсэлтийг шийдэхэд тоолуур өөрчлөгдөхгүй.
            RETURN NEW;
        END IF;

        IF session_row.confirmed_count < session_row.capacity AND session_row.waiting_count = 0 THEN
            UPDATE class_session SET confirmed_count = confirmed_count + 1
            WHERE session_id = target_session_id;
        ELSE
            UPDATE class_session
            SET waiting_count = waiting_count + 1, last_waitlist_number = last_waitlist_number + 1
            WHERE session_id = target_session_id
            RETURNING last_waitlist_number INTO NEW.waitlist_number;
        END IF;
    ELSIF TG_OP = 'UPDATE' AND NEW.waitlist_number IS DISTINCT FROM OLD.waitlist_number THEN
        -- Сул суудалд хүлээлгийн хамгийн бага дугаартай гишүүнийг шилжүүлж болно.
        IF NEW.waitlist_number IS NOT NULL OR OLD.waitlist_number IS NULL
            OR session_row.confirmed_count >= session_row.capacity
            OR EXISTS (
                SELECT 1 FROM class_booking AS booking
                WHERE booking.session_id = target_session_id
                  AND booking.waitlist_number < OLD.waitlist_number
            )
        THEN
            RAISE EXCEPTION 'Сул суудлыг зөвхөн хүлээлгийн эхний гишүүнд олгоно'
                USING ERRCODE = '23514';
        END IF;
        UPDATE class_session
        SET confirmed_count = confirmed_count + 1, waiting_count = waiting_count - 1
        WHERE session_id = target_session_id;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE class_session
        SET confirmed_count = confirmed_count - (OLD.waitlist_number IS NULL)::integer,
            waiting_count = waiting_count - (OLD.waitlist_number IS NOT NULL)::integer
        WHERE session_id = target_session_id;
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER class_booking_changes
BEFORE INSERT OR UPDATE OR DELETE ON class_booking
FOR EACH ROW EXECUTE FUNCTION maintain_class_booking();

CREATE FUNCTION register_for_class(target_session_id integer, target_member_id integer)
RETURNS TABLE (session_id integer, member_id integer, status text, waitlist_number integer)
LANGUAGE plpgsql
SET search_path TO pg_catalog, fitness
AS $$
BEGIN
    INSERT INTO class_booking (session_id, member_id)
    VALUES (target_session_id, target_member_id)
    ON CONFLICT ON CONSTRAINT class_booking_pkey DO NOTHING;

    RETURN QUERY
    SELECT booking.session_id, booking.member_id, booking.status, booking.waitlist_number
    FROM class_booking AS booking
    WHERE booking.session_id = target_session_id AND booking.member_id = target_member_id;
END;
$$;

CREATE FUNCTION contract_status(target_contract_id integer, on_day date) RETURNS text
LANGUAGE sql STABLE STRICT
SET search_path TO pg_catalog, fitness
AS $$
    SELECT CASE
        WHEN on_day < contract.starts_on THEN 'upcoming'
        WHEN on_day >= contract.expires_on THEN 'expired'
        WHEN EXISTS (
            SELECT 1
            FROM membership_freeze AS pause
            WHERE pause.contract_id = contract.contract_id
              AND on_day >= pause.starts_on AND on_day < pause.resumes_on
        ) THEN 'frozen'
        ELSE 'active'
    END
    FROM membership_contract AS contract
    WHERE contract.contract_id = target_contract_id;
$$;

CREATE VIEW active_members AS
SELECT member_id, joined_on, is_active
FROM member
WHERE is_active
WITH LOCAL CHECK OPTION;

CREATE VIEW contract_balances AS
SELECT contract.contract_id, contract.member_id, contract.plan_id,
       contract.starts_on, contract.expires_on, contract.frozen_days, contract.agreed_price_mnt,
       coalesce(sum(payment.amount_mnt), 0) AS paid_mnt,
       contract.agreed_price_mnt - coalesce(sum(payment.amount_mnt), 0) AS balance_mnt
FROM membership_contract AS contract
LEFT JOIN payment USING (contract_id)
GROUP BY contract.contract_id;

CREATE VIEW class_availability AS
SELECT session_id, class_name, trainer_id, starts_at, capacity,
       confirmed_count, waiting_count, capacity - confirmed_count AS available_spots
FROM class_session;

COMMIT;

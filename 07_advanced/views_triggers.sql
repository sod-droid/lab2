\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path = tucson, pg_catalog;

CREATE FUNCTION contract_status(id integer, d date) RETURNS text
LANGUAGE sql STABLE STRICT SET search_path FROM CURRENT AS $$
    SELECT CASE WHEN d < c.starts_on THEN 'upcoming'
                WHEN d >= c.access_until THEN 'cancelled'
                WHEN d >= c.expires_on THEN 'expired'
                WHEN EXISTS (SELECT FROM membership_freeze f WHERE f.contract_id=id
                             AND d>=f.starts_on AND d<f.resumes_on) THEN 'frozen'
                ELSE 'active' END
    FROM membership_contract c WHERE c.contract_id=id
$$;

CREATE FUNCTION billing_boundary(id integer, n integer) RETURNS date
LANGUAGE plpgsql STABLE STRICT SET search_path FROM CURRENT AS $$
DECLARE boundary date; pause record;
BEGIN
    SELECT (starts_on + make_interval(months=>n))::date INTO STRICT boundary
    FROM membership_contract WHERE contract_id=id;
    IF n=0 THEN RETURN boundary; END IF;
    FOR pause IN SELECT starts_on,resumes_on FROM membership_freeze
                 WHERE contract_id=id ORDER BY starts_on LOOP
        EXIT WHEN pause.starts_on > boundary;
        boundary := boundary + (pause.resumes_on-pause.starts_on);
    END LOOP;
    RETURN boundary;
END $$;

CREATE FUNCTION set_contract_terms() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE p membership_plan%ROWTYPE; m member%ROWTYPE;
BEGIN
    SELECT * INTO STRICT p FROM membership_plan WHERE plan_id=NEW.plan_id;
    SELECT * INTO STRICT m FROM member WHERE member_id=NEW.member_id FOR UPDATE;
    IF TG_OP='INSERT' THEN
        IF NEW.periods<>1 THEN
            RAISE EXCEPTION 'Шинэ гэрээ эхний нэг мөчлөгөөс эхэлнэ' USING ERRCODE='23514';
        END IF;
        IF NOT (NEW.starts_on <@ daterange(p.valid_from,p.valid_until,'[)')) OR NEW.starts_on<m.joined_on THEN
            RAISE EXCEPTION 'Гэрээний өдөр багц эсвэл гишүүний хүчинтэй хугацаанаас гадуур' USING ERRCODE='23514';
        END IF;
        NEW.agreed_usd := p.price_usd;
        IF p.product_code='PASS_MEMBER' AND NOT EXISTS (
            SELECT FROM membership_contract c JOIN membership_plan op USING(plan_id)
            WHERE c.member_id=NEW.member_id AND op.product_code IN ('OPEN59','OPEN69')
              AND contract_status(c.contract_id,NEW.starts_on)='active'
        ) THEN RAISE EXCEPTION 'Хөнгөлөлттэй карт авахад идэвхтэй Open Gym гэрээ шаардлагатай' USING ERRCODE='23514'; END IF;
        IF p.product_code='PASS' AND coalesce(m.intro_completed_on,'infinity'::date)>NEW.starts_on THEN
            RAISE EXCEPTION 'Гаднын гишүүний картын өмнө ганцаарчилсан хичээл шаардлагатай' USING ERRCODE='23514';
        END IF;
    ELSIF (NEW.member_id,NEW.plan_id,NEW.starts_on,NEW.agreed_usd,NEW.bundle_usd,NEW.consultation_waiver)
        IS DISTINCT FROM (OLD.member_id,OLD.plan_id,OLD.starts_on,OLD.agreed_usd,OLD.bundle_usd,OLD.consultation_waiver) THEN
        RAISE EXCEPTION 'Баталгаажсан гэрээний тариф ба эзэмшигчийг өөрчлөхгүй' USING ERRCODE='23514';
    END IF;
    IF (p.product_code IN ('BASE','OPTIMAL')) <> (NEW.bundle_usd IS NOT NULL)
       OR NEW.bundle_usd NOT BETWEEN p.bundle_min_usd AND p.bundle_max_usd THEN
        RAISE EXCEPTION 'Эхний багцын дүн зөвшөөрсөн мужаас гадуур' USING ERRCODE='23514';
    END IF;
    IF p.product_code IN ('PASS','PASS_MEMBER','RESET') AND NEW.periods<>1 THEN
        RAISE EXCEPTION 'Нэг удаагийн багц автоматаар сунгагдахгүй' USING ERRCODE='23514';
    END IF;
    NEW.base_expires_on := CASE WHEN p.product_code='RESET' THEN NEW.starts_on+42
        WHEN p.product_code IN ('PASS','PASS_MEMBER') THEN NULL
        ELSE (NEW.starts_on + make_interval(months=>NEW.periods))::date END;
    RETURN NEW;
END $$;
CREATE TRIGGER contract_terms BEFORE INSERT OR UPDATE OF member_id,plan_id,starts_on,agreed_usd,
    bundle_usd,consultation_waiver,periods,base_expires_on ON membership_contract
    FOR EACH ROW EXECUTE FUNCTION set_contract_terms();

CREATE FUNCTION post_signup() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE p membership_plan%ROWTYPE; fee numeric; charge text;
BEGIN
    SELECT * INTO STRICT p FROM membership_plan WHERE plan_id=NEW.plan_id;
    charge := CASE WHEN p.product_code IN ('BASE','OPTIMAL') THEN 'bundle'
                   WHEN p.product_code LIKE 'PASS%' THEN 'pass' WHEN p.product_code='RESET' THEN 'reset' ELSE 'dues' END;
    INSERT INTO invoice(contract_id,member_id,kind,due_on,cycle_index,coverage_end,subtotal_usd)
    VALUES (NEW.contract_id,NEW.member_id,charge,NEW.starts_on,CASE WHEN charge IN ('dues','bundle') THEN 0 END,
        CASE WHEN charge IN ('bundle','dues') THEN billing_boundary(NEW.contract_id,1) END,
        coalesce(NEW.bundle_usd,NEW.agreed_usd));
    SELECT CASE WHEN NEW.consultation_waiver THEN 0 WHEN discount_group IS NOT NULL
                THEN p.enrollment_usd/2 ELSE p.enrollment_usd END INTO fee FROM member WHERE member_id=NEW.member_id;
    IF fee>0 THEN
        INSERT INTO invoice(contract_id,member_id,kind,due_on,subtotal_usd)
        VALUES(NEW.contract_id,NEW.member_id,'enrollment',NEW.starts_on,fee);
    END IF;
    IF p.product_code='PASS' AND NOT EXISTS(SELECT FROM invoice WHERE member_id=NEW.member_id AND kind='intro') THEN
        INSERT INTO invoice(contract_id,member_id,kind,due_on,subtotal_usd)
        VALUES (NEW.contract_id,NEW.member_id,'intro',NEW.starts_on,80);
    END IF;
    IF p.product_code NOT LIKE 'PASS%' THEN
        INSERT INTO invoice(contract_id,member_id,kind,due_on,subtotal_usd)
        VALUES (NEW.contract_id,NEW.member_id,'rfid',NEW.starts_on,12)
        ON CONFLICT (member_id) WHERE kind='rfid' DO NOTHING;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER signup_charges AFTER INSERT ON membership_contract FOR EACH ROW EXECUTE FUNCTION post_signup();

CREATE FUNCTION renew_month(id integer) RETURNS date LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE c membership_contract%ROWTYPE; mid integer; p text; due date; until_day date;
BEGIN
    SELECT member_id INTO STRICT mid FROM membership_contract WHERE contract_id=id;
    PERFORM 1 FROM member WHERE member_id=mid FOR UPDATE;
    SELECT * INTO STRICT c FROM membership_contract WHERE contract_id=id FOR UPDATE;
    SELECT product_code INTO p FROM membership_plan WHERE plan_id=c.plan_id;
    due:=billing_boundary(id,c.periods);
    until_day:=billing_boundary(id,c.periods+1);
    IF p NOT IN ('OPEN59','OPEN69','BASE','OPTIMAL') OR due>=c.access_until THEN
        RAISE EXCEPTION 'Энэ багц эсвэл хаагдсан гэрээг сараар сунгах боломжгүй' USING ERRCODE='23514';
    END IF;
    INSERT INTO invoice(contract_id,member_id,kind,due_on,cycle_index,coverage_end,subtotal_usd)
    VALUES (id,c.member_id,'dues',due,c.periods,until_day,c.agreed_usd);
    UPDATE membership_contract SET periods=periods+1 WHERE contract_id=id;
    RETURN until_day;
END $$;

CREATE FUNCTION maintain_freeze() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE c membership_contract%ROWTYPE; id integer; mid integer; advance integer;
BEGIN
    IF TG_OP='UPDATE' AND NEW.contract_id<>OLD.contract_id THEN
        RAISE EXCEPTION 'Түр зогсолтын гэрээг сольж болохгүй' USING ERRCODE='23514';
    END IF;
    id:=CASE WHEN TG_OP='DELETE' THEN OLD.contract_id ELSE NEW.contract_id END;
    SELECT member_id INTO STRICT mid FROM membership_contract WHERE contract_id=id;
    UPDATE member SET is_active=is_active WHERE member_id=mid;
    SELECT * INTO STRICT c FROM membership_contract WHERE contract_id=id FOR UPDATE;
    IF TG_OP<>'DELETE' AND NOT EXISTS(SELECT FROM membership_plan WHERE plan_id=c.plan_id
                 AND product_code IN ('OPEN59','OPEN69','BASE','OPTIMAL','RESET')) THEN
        RAISE EXCEPTION 'Хугацаатай багцад түр зогсолт бүртгэнэ' USING ERRCODE='23514';
    END IF;
    IF EXISTS (SELECT FROM membership_freeze f JOIN membership_contract mc USING(contract_id)
        CROSS JOIN generate_series(0,29) AS offset_days(n) WHERE mc.member_id=mid
        GROUP BY extract(year FROM f.starts_on+n) HAVING count(*)>30) THEN
        RAISE EXCEPTION 'Жилийн сургалтын хязгаар 30 хоног' USING ERRCODE='23514';
    END IF;
    IF EXISTS (SELECT FROM (SELECT starts_on,requested_on,row_number() OVER(ORDER BY starts_on)-1 AS prior
              FROM membership_freeze WHERE contract_id=id) t
        WHERE t.requested_on<c.starts_on OR t.starts_on>=c.base_expires_on+30*t.prior::integer
           OR t.starts_on+30>c.access_until) THEN
        RAISE EXCEPTION 'Зогсолт нь гэрээний идэвхтэй хугацаанд багтана' USING ERRCODE='23514';
    END IF;
    IF TG_OP<>'INSERT' AND (TG_OP='DELETE' OR OLD.starts_on<>NEW.starts_on) THEN
        DELETE FROM invoice WHERE contract_id=id AND kind='freeze' AND due_on=OLD.starts_on;
    END IF;
    IF TG_OP<>'DELETE' AND (TG_OP='INSERT' OR OLD.starts_on<>NEW.starts_on) THEN
        INSERT INTO invoice(contract_id,member_id,kind,due_on,subtotal_usd) VALUES(id,mid,'freeze',NEW.starts_on,15);
    END IF;
    UPDATE membership_contract SET frozen_days=(SELECT count(*)::integer*30 FROM membership_freeze WHERE contract_id=id)
    WHERE contract_id=id;
    FOR advance IN 0..c.periods-1 LOOP
        UPDATE invoice SET due_on=billing_boundary(id,advance),coverage_end=billing_boundary(id,advance+1)
        WHERE contract_id=id AND kind IN ('dues','bundle')
          AND cycle_index=advance;
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER freeze_changes AFTER INSERT OR UPDATE OR DELETE ON membership_freeze
FOR EACH ROW EXECUTE FUNCTION maintain_freeze();

CREATE FUNCTION invoice_position(d date)
RETURNS TABLE(invoice_id integer,contract_id integer,member_id integer,due_on date,
              billed numeric,credit numeric,net_paid numeric,balance numeric,refund_due numeric)
LANGUAGE sql STABLE STRICT SET search_path FROM CURRENT AS $$
    WITH settlements AS (
        SELECT p.invoice_id,sum(p.net_usd) AS paid FROM payment p WHERE p.paid_on<=d GROUP BY p.invoice_id
    ), lines AS (
        SELECT i.*, coalesce(s.paid,0) AS paid,
            CASE WHEN i.kind='dues' AND c.cancel_requested_on<=d AND i.due_on>=c.access_until THEN i.total_usd
                 WHEN i.kind='dues' AND c.cancel_requested_on<=d AND i.due_on>=c.cancel_requested_on
                   AND i.due_on<c.access_until AND i.coverage_end>c.access_until
                 THEN round(i.total_usd*(i.coverage_end-c.access_until)/(i.coverage_end-i.due_on),2)
                 ELSE 0 END AS unused
        FROM invoice i JOIN membership_contract c USING(contract_id)
        LEFT JOIN settlements s USING(invoice_id) WHERE i.due_on<=d
    )
    SELECT l.invoice_id,l.contract_id,l.member_id,l.due_on,l.total_usd,l.unused,l.paid,
           greatest(0,l.total_usd-l.unused-l.paid),
           greatest(0,least(l.unused,l.paid-(l.total_usd-l.unused)))
    FROM lines l
$$;
CREATE VIEW active_members AS SELECT member_id,joined_on,is_active FROM member
WHERE is_active WITH LOCAL CHECK OPTION;
CREATE VIEW contract_balances AS SELECT contract_id,member_id,sum(balance) AS balance_usd
FROM invoice_position((CURRENT_TIMESTAMP AT TIME ZONE 'America/Phoenix')::date) GROUP BY contract_id,member_id;
CREATE VIEW class_availability AS SELECT session_id,trainer_id,class_name,starts_at,capacity,
    confirmed_count,waiting_count,capacity-confirmed_count AS available_spots FROM class_session;
CREATE VIEW waiting_order AS
SELECT b.session_id,b.member_id,b.waitlist_number,row_number() OVER(PARTITION BY b.session_id ORDER BY
    CASE WHEN s.class_name='Barbell Club' AND (s.starts_at AT TIME ZONE 'America/Phoenix')::time=time '17:00'
         AND p.product_code='OPTIMAL' THEN 0 ELSE 1 END, b.waitlist_number) AS position
FROM class_booking b JOIN class_session s USING(session_id)
JOIN membership_contract c USING(contract_id) JOIN membership_plan p USING(plan_id) WHERE b.status='waitlisted';

CREATE FUNCTION check_entitlement(s class_session, cid integer, mid integer, checked_at timestamptz) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE day date := (s.starts_at AT TIME ZONE 'America/Phoenix')::date;
    checked_day date := (checked_at AT TIME ZONE 'America/Phoenix')::date;
    c membership_contract%ROWTYPE; p text; m member%ROWTYPE; cycle_start date; cycle_end date; used integer;
BEGIN
    UPDATE member SET is_active=is_active WHERE member_id=mid RETURNING * INTO STRICT m;
    SELECT * INTO STRICT c FROM membership_contract WHERE contract_id=cid AND member_id=mid;
    SELECT product_code INTO p FROM membership_plan WHERE plan_id=c.plan_id;
    IF NOT m.is_active OR contract_status(cid,day)<>'active' OR p IN ('OPEN59','OPEN69')
       OR m.intro_completed_on IS NULL OR m.intro_completed_on>least(day,checked_day) THEN
        RAISE EXCEPTION 'Ангид орох идэвхтэй багц, анхан шатны хичээл шаардлагатай' USING ERRCODE='23514';
    END IF;
    IF EXISTS (SELECT FROM invoice_position(checked_day) i WHERE i.member_id=mid
               AND i.due_on<=checked_day-10 AND i.balance>0) THEN
        RAISE EXCEPTION '10 хоног хэтэрсэн өртэй' USING ERRCODE='23514';
    END IF;
    IF p='BASE' THEN
        SELECT i.due_on,i.coverage_end INTO STRICT cycle_start,cycle_end FROM invoice i WHERE i.contract_id=cid
          AND i.kind IN ('bundle','dues') AND day>=i.due_on AND day<i.coverage_end;
    END IF;
    SELECT count(*) INTO used FROM class_booking b JOIN class_session x USING(session_id)
    WHERE b.member_id=mid AND b.session_id<>s.session_id AND b.status IN ('confirmed','late_cancelled') AND
      (CASE WHEN p='OPTIMAL' THEN (x.starts_at AT TIME ZONE 'America/Phoenix')::date=day
            WHEN p='BASE' THEN b.contract_id=cid AND (x.starts_at AT TIME ZONE 'America/Phoenix')::date>=cycle_start
                AND (x.starts_at AT TIME ZONE 'America/Phoenix')::date<cycle_end
            WHEN p IN ('PASS','PASS_MEMBER') THEN b.contract_id=cid ELSE false END);
    IF (p='BASE' AND used>=9) OR (p='OPTIMAL' AND used>=1) OR (p LIKE 'PASS%' AND used>=10) THEN
        RAISE EXCEPTION 'Ангийн эрхийн хязгаар дууссан' USING ERRCODE='23514';
    END IF;
END $$;

CREATE FUNCTION manage_booking() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    s class_session%ROWTYPE;
    sid integer;
    first_member integer;
    confirmed integer;
    waiting integer;
    latest_number integer;
BEGIN
    sid:=CASE WHEN TG_OP='DELETE' THEN OLD.session_id ELSE NEW.session_id END;
    SELECT * INTO STRICT s FROM class_session WHERE session_id=sid FOR UPDATE;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    SELECT count(*) FILTER (WHERE status='confirmed'), count(*) FILTER (WHERE status='waitlisted'),
           greatest(max(waitlist_number),s.last_waitlist_number)
    INTO confirmed,waiting,latest_number FROM class_booking WHERE session_id=sid;
    IF TG_OP='INSERT' THEN
        IF NEW.booked_at>=s.starts_at OR NEW.cancelled_at IS NOT NULL OR NEW.status NOT IN ('confirmed','waitlisted') THEN
            RAISE EXCEPTION 'Захиалгыг хичээл эхлэхээс өмнө бүртгэнэ' USING ERRCODE='23514';
        END IF;
        PERFORM check_entitlement(s,NEW.contract_id,NEW.member_id,NEW.booked_at);
        NEW.status:=CASE WHEN confirmed<s.capacity AND waiting=0 THEN 'confirmed' ELSE 'waitlisted' END;
        IF NEW.status='waitlisted' THEN NEW.waitlist_number:=latest_number+1; ELSE NEW.waitlist_number:=NULL; END IF;
    ELSE
        IF (NEW.session_id,NEW.member_id,NEW.contract_id,NEW.booked_at) IS DISTINCT FROM
           (OLD.session_id,OLD.member_id,OLD.contract_id,OLD.booked_at) THEN
            RAISE EXCEPTION 'Захиалгын таних утгыг сольж болохгүй' USING ERRCODE='23514';
        END IF;
        IF OLD.status IN ('confirmed','waitlisted') AND NEW.cancelled_at IS NOT NULL THEN
            IF NEW.cancelled_at>s.starts_at THEN RAISE EXCEPTION 'Хичээл эхэлсний дараа захиалга цуцлахгүй' USING ERRCODE='23514'; END IF;
            NEW.status:=CASE WHEN OLD.status='confirmed' AND NEW.cancelled_at>s.starts_at-interval '2 hours'
                THEN 'late_cancelled' ELSE 'cancelled' END;
            NEW.waitlist_number:=NULL;
        ELSIF OLD.status='waitlisted' AND NEW.status='confirmed' THEN
            SELECT member_id INTO first_member FROM waiting_order WHERE session_id=sid AND position=1;
            IF OLD.member_id<>first_member OR confirmed>=s.capacity THEN
                RAISE EXCEPTION 'Эхний хүлээгчид сул суудал олгоно' USING ERRCODE='23514'; END IF;
            IF CURRENT_TIMESTAMP>=s.starts_at THEN RAISE EXCEPTION 'Эхэлсэн ангид хүлээлтээс шилжүүлэхгүй' USING ERRCODE='23514'; END IF;
            PERFORM check_entitlement(s,NEW.contract_id,NEW.member_id,CURRENT_TIMESTAMP);
            NEW.waitlist_number:=NULL;
        ELSIF (NEW.status,NEW.waitlist_number,NEW.cancelled_at) IS DISTINCT FROM
              (OLD.status,OLD.waitlist_number,OLD.cancelled_at) THEN
            RAISE EXCEPTION 'Хүлээлт ба цуцлалтын төлөв буруу' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER booking_changes BEFORE INSERT OR UPDATE OR DELETE ON class_booking
FOR EACH ROW EXECUTE FUNCTION manage_booking();

CREATE FUNCTION sync_booking_counts() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE sid integer; old_status text; new_status text; number integer;
BEGIN
    sid:=CASE WHEN TG_OP='DELETE' THEN OLD.session_id ELSE NEW.session_id END;
    old_status:=CASE WHEN TG_OP='INSERT' THEN '' ELSE OLD.status END;
    new_status:=CASE WHEN TG_OP='DELETE' THEN '' ELSE NEW.status END;
    number:=CASE WHEN TG_OP='DELETE' THEN NULL ELSE NEW.waitlist_number END;
    UPDATE class_session
    SET confirmed_count=confirmed_count+(new_status='confirmed')::int-(old_status='confirmed')::int,
        waiting_count=waiting_count+(new_status='waitlisted')::int-(old_status='waitlisted')::int,
        last_waitlist_number=greatest(last_waitlist_number,number)
    WHERE session_id=sid;
    RETURN NULL;
END $$;
CREATE TRIGGER booking_counts AFTER INSERT OR UPDATE OR DELETE ON class_booking
FOR EACH ROW EXECUTE FUNCTION sync_booking_counts();

CREATE FUNCTION register_for_class(sid integer,mid integer,cid integer,at_time timestamptz DEFAULT CURRENT_TIMESTAMP)
RETURNS TABLE(status text,waitlist_number integer) LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    PERFORM 1 FROM class_session WHERE session_id=sid FOR UPDATE;
    IF NOT EXISTS(SELECT FROM class_booking b WHERE b.session_id=sid AND b.member_id=mid) THEN
        INSERT INTO class_booking(session_id,member_id,contract_id,booked_at) VALUES(sid,mid,cid,at_time);
    END IF;
    RETURN QUERY SELECT b.status,b.waitlist_number FROM class_booking b WHERE b.session_id=sid AND b.member_id=mid;
END $$;
CREATE FUNCTION check_refund() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE available numeric; collected numeric;
BEGIN
    IF NEW.kind='refund' THEN
        PERFORM 1 FROM invoice WHERE invoice_id=NEW.invoice_id FOR UPDATE;
        SELECT refund_due INTO available FROM invoice_position(NEW.paid_on) WHERE invoice_id=NEW.invoice_id;
        SELECT sum(net_usd) INTO collected FROM payment WHERE invoice_id=NEW.invoice_id
            AND method=NEW.method AND paid_on<=NEW.paid_on;
        IF NEW.amount_usd>least(coalesce(available,0),coalesce(collected,0)) THEN
            RAISE EXCEPTION 'Буцаалтын дүн эсвэл төлбөрийн арга эх баримттай зөрөв' USING ERRCODE='23514';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER refund_validation BEFORE INSERT ON payment FOR EACH ROW EXECUTE FUNCTION check_refund();

CREATE FUNCTION check_attendance() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE day date; cid integer; meeting timestamptz;
BEGIN
    SELECT s.starts_at,b.contract_id INTO STRICT meeting,cid FROM class_booking b JOIN class_session s USING(session_id)
    WHERE b.session_id=NEW.session_id AND b.member_id=NEW.member_id;
    day:=(meeting AT TIME ZONE 'America/Phoenix')::date;
    IF NEW.recorded_at<meeting OR (NEW.attended AND (contract_status(cid,day)<>'active'
        OR NOT EXISTS(SELECT FROM active_members WHERE member_id=NEW.member_id)
        OR EXISTS(SELECT FROM invoice_position(day) i WHERE i.member_id=NEW.member_id AND i.due_on<=day-10 AND i.balance>0))) THEN
        RAISE EXCEPTION 'Ирцийн цаг эсвэл тухайн өдрийн нэвтрэх эрх буруу' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER attendance_validation BEFORE INSERT OR UPDATE ON attendance FOR EACH ROW EXECUTE FUNCTION check_attendance();
COMMIT;

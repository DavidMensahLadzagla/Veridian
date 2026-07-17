-- ---------------------------------------------------------------------------
-- UTILITY: auto-update updated_at
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- updated_at triggers (verbatim from veridian_schema.sql, one per mutable table)
-- ---------------------------------------------------------------------------
CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_user_auth_providers_updated_at
    BEFORE UPDATE ON user_auth_providers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_device_tokens_updated_at
    BEFORE UPDATE ON device_tokens
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_service_categories_updated_at
    BEFORE UPDATE ON service_categories
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_feature_flags_updated_at
    BEFORE UPDATE ON feature_flags
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_notification_templates_updated_at
    BEFORE UPDATE ON notification_templates
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_notification_log_updated_at
    BEFORE UPDATE ON notification_log
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_notification_preferences_updated_at
    BEFORE UPDATE ON notification_preferences
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_payment_transactions_updated_at
    BEFORE UPDATE ON payment_transactions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_payouts_updated_at
    BEFORE UPDATE ON payouts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_bank_accounts_updated_at
    BEFORE UPDATE ON bank_accounts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_patient_profiles_updated_at
    BEFORE UPDATE ON patient_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_specializations_updated_at
    BEFORE UPDATE ON specializations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_clinics_updated_at
    BEFORE UPDATE ON clinics
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_doctor_profiles_updated_at
    BEFORE UPDATE ON doctor_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_doctor_qualifications_updated_at
    BEFORE UPDATE ON doctor_qualifications
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_clinic_affiliations_updated_at
    BEFORE UPDATE ON clinic_affiliations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_availability_templates_updated_at
    BEFORE UPDATE ON availability_templates
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_slots_updated_at
    BEFORE UPDATE ON slots
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_pre_consultation_form_templates_updated_at
    BEFORE UPDATE ON pre_consultation_form_templates
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_appointments_updated_at
    BEFORE UPDATE ON appointments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_health_timeline_entries_updated_at
    BEFORE UPDATE ON health_timeline_entries
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_consent_grants_updated_at
    BEFORE UPDATE ON consent_grants
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_reviews_updated_at
    BEFORE UPDATE ON reviews
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_documents_updated_at
    BEFORE UPDATE ON documents
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_telehealth_sessions_updated_at
    BEFORE UPDATE ON telehealth_sessions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---- Append-only guard ----------------------------------------------------
-- No legitimate code path ever UPDATEs or DELETEs audit_log. Triggers raise
-- an exception so even a direct psql session (short of superuser ALTER TABLE)
-- cannot mutate a historic row.
CREATE OR REPLACE FUNCTION audit_log_reject_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is append-only (action=%)', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_log_no_update
    BEFORE UPDATE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_reject_mutation();

CREATE TRIGGER trg_audit_log_no_delete
    BEFORE DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_reject_mutation();

-- TRUNCATE fires statement-level triggers; guard that path too.
CREATE TRIGGER trg_audit_log_no_truncate
    BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION audit_log_reject_mutation();

-- ---- Hash chain ----------------------------------------------------------
-- Each new row is linked to the previous row's hash, so altering any
-- historical row invalidates every subsequent row_hash. The periodic
-- verifier (RB-17) detects drift between the computed chain and the
-- previously-signed block heads archived to S3 Object Lock.
CREATE OR REPLACE FUNCTION audit_log_chain() RETURNS trigger AS $$
DECLARE
    last_hash BYTEA;
BEGIN
    SELECT row_hash INTO last_hash
    FROM audit_log
    ORDER BY id DESC
    LIMIT 1;

    NEW.prev_row_hash := COALESCE(last_hash, '\x00'::bytea);
    NEW.row_hash := digest(
        COALESCE(encode(NEW.prev_row_hash, 'hex'), '') ||
        COALESCE(NEW.actor_id::text, '') || '|' ||
        NEW.table_name || '|' ||
        NEW.record_id::text || '|' ||
        NEW.action || '|' ||
        COALESCE(NEW.before_state::text, '') || '|' ||
        COALESCE(NEW.after_state::text, '') || '|' ||
        COALESCE(host(NEW.ip_address), '') || '|' ||
        COALESCE(NEW.user_agent, '') || '|' ||
        NEW.created_at::text,
        'sha256'
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_log_chain
    BEFORE INSERT ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_chain();
-- Requires the `pgcrypto` extension for digest() (already enabled at top of file).

-- ---------------------------------------------------------------------------
-- Model/DDL reconciliation (ADR-0006):
-- These columns are null=True in the Django models because their values are
-- supplied by the database (trigger / default), which Django cannot express.
-- The canonical DDL declares them NOT NULL; enforce that here, after the
-- trigger and default exist. Tables are empty at this point in the migration
-- graph, so SET NOT NULL cannot fail on existing rows.
-- ---------------------------------------------------------------------------
ALTER TABLE patient_profiles
    ALTER COLUMN patient_key_salt SET DEFAULT gen_random_bytes(32);
ALTER TABLE patient_profiles
    ALTER COLUMN patient_key_salt SET NOT NULL;

ALTER TABLE audit_log
    ALTER COLUMN row_hash SET NOT NULL;

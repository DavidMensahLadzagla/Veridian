-- =============================================================================
-- Veridian DATABASE SCHEMA
-- Document 1 of 10 — Database Schema & DDL
-- Platform: Supabase (PostgreSQL 15+)
-- Currency: Multi-currency (amount in minor units + currency_code)
-- Conventions:
--   - All PKs are UUIDs (gen_random_uuid())
--   - All tables have created_at, updated_at, deleted_at (soft delete)
--   - Money stored as INTEGER (minor units, e.g. pesewas) + VARCHAR(3) currency_code
--   - Enums defined as PostgreSQL TYPE
--   - RLS enabled on every table
--   - Indexes defined after table creation
-- =============================================================================

-- ---------------------------------------------------------------------------
-- EXTENSIONS
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "postgis";         -- proximity search
CREATE EXTENSION IF NOT EXISTS "vector";          -- pgvector for semantic search

-- ---------------------------------------------------------------------------
-- SHARED ENUMS
-- ---------------------------------------------------------------------------

CREATE TYPE user_role AS ENUM (
    'patient',
    'doctor',
    'clinic_admin',
    'platform_admin'
);

CREATE TYPE verification_status AS ENUM (
    'unverified',
    'pending_review',
    'verified',
    'rejected',
    'suspended'
);

CREATE TYPE booking_mode AS ENUM (
    'in_person',
    'telehealth',
    'either'
);

CREATE TYPE appointment_status AS ENUM (
    'requested',
    'confirmed',
    'in_progress',
    'completed',
    'cancelled_by_patient',
    'cancelled_by_doctor',
    'cancelled_by_platform',
    'no_show_patient',
    'no_show_doctor'
);

CREATE TYPE slot_status AS ENUM (
    'available',
    'reserved',
    'booked',
    'blocked',
    'expired'
);

CREATE TYPE notification_channel AS ENUM (
    'push',
    'sms',
    'email',
    'in_app'
);

CREATE TYPE notification_status AS ENUM (
    'pending',
    'sent',
    'delivered',
    'failed'
);

CREATE TYPE payment_status AS ENUM (
    'pending',
    'authorized',
    'captured',
    'failed',
    'refunded',
    'partially_refunded',
    'disputed'
);

CREATE TYPE payment_provider AS ENUM (
    'paystack',
    'stripe',
    'cash'
);

CREATE TYPE payout_status AS ENUM (
    'pending',
    'processing',
    'completed',
    'failed'
);

CREATE TYPE timeline_entry_type AS ENUM (
    'symptom_log',
    'diagnosis_note',
    'prescription',
    'lab_result',
    'patient_note',
    'vaccination',
    'allergy_record'
);

CREATE TYPE timeline_visibility AS ENUM (
    'patient_only',
    'shared_with_current_doctor',
    'shared_with_all_future_doctors'
);

CREATE TYPE consent_scope AS ENUM (
    'read_timeline',
    'read_prescriptions',
    'read_lab_results',
    'read_all'
);

CREATE TYPE day_of_week AS ENUM (
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday'
);

CREATE TYPE service_category AS ENUM (
    'medical',
    'barber',
    'mechanic'
    -- extend here when new verticals are added
);

CREATE TYPE review_status AS ENUM (
    'pending',
    'published',
    'flagged',
    'removed'
);

CREATE TYPE gender AS ENUM (
    'male',
    'female',
    'non_binary',
    'prefer_not_to_say'
);

CREATE TYPE document_type AS ENUM (
    'medical_license',
    'national_id',
    'proof_of_address',
    'qualification_certificate',
    'lab_result',
    'prescription',
    'insurance_card',
    'other'
);

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
-- ============================================================
-- LAYER 1: SHARED PLATFORM TABLES
-- ============================================================
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. users
-- The single identity table for all roles. Role-specific profile data
-- lives in separate tables (patient_profiles, doctor_profiles, etc.)
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email               VARCHAR(320) UNIQUE,                  -- nullable (phone-only signup allowed)
    phone               VARCHAR(20) UNIQUE,                   -- E.164 format e.g. +233201234567
    phone_verified      BOOLEAN NOT NULL DEFAULT FALSE,
    email_verified      BOOLEAN NOT NULL DEFAULT FALSE,
    role                user_role NOT NULL DEFAULT 'patient',
    full_name           VARCHAR(200) NOT NULL,
    preferred_language  VARCHAR(10) NOT NULL DEFAULT 'en',    -- BCP 47 e.g. 'en', 'tw' (Twi)
    avatar_storage_key  TEXT,                                 -- Supabase Storage key
    timezone            VARCHAR(60) NOT NULL DEFAULT 'Africa/Accra',
    date_of_birth       DATE,
    gender              gender,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    last_login_at       TIMESTAMPTZ,
    -- Soft delete
    deleted_at          TIMESTAMPTZ,
    -- Audit
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT users_email_or_phone CHECK (
        email IS NOT NULL OR phone IS NOT NULL
    )
);

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. user_auth_providers
-- Tracks OAuth providers linked to a user (Google, Apple)
-- ---------------------------------------------------------------------------
CREATE TABLE user_auth_providers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider        VARCHAR(50) NOT NULL,   -- 'google', 'apple'
    provider_uid    VARCHAR(255) NOT NULL,  -- provider's user ID
    access_token    TEXT,                  -- encrypted at app level
    refresh_token   TEXT,                  -- encrypted at app level
    expires_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (provider, provider_uid)
);

CREATE TRIGGER trg_user_auth_providers_updated_at
    BEFORE UPDATE ON user_auth_providers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. device_tokens
-- FCM/APNS push tokens per device per user
-- ---------------------------------------------------------------------------
CREATE TABLE device_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token       TEXT NOT NULL UNIQUE,
    platform    VARCHAR(10) NOT NULL CHECK (platform IN ('ios', 'android', 'web')),
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    last_used_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_device_tokens_updated_at
    BEFORE UPDATE ON device_tokens
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. refresh_token_blocklist
-- Revoked JWT refresh tokens (Redis is primary; this is the durable fallback)
-- ---------------------------------------------------------------------------
CREATE TABLE refresh_token_blocklist (
    jti         UUID PRIMARY KEY,          -- JWT ID claim
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    revoked_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at  TIMESTAMPTZ NOT NULL       -- purge cron deletes rows past this date
);

-- ---------------------------------------------------------------------------
-- 4b. idempotency_keys  (ADR-0002)
-- At-least-once delivery from the Flutter offline queue must yield at-most-once
-- server effect. Django-only (service-role written); clients never read this.
-- Flow: INSERT ... ON CONFLICT DO NOTHING with status='in_progress'. If the
-- insert wins, this is the first execution; on completion store the response.
-- If it conflicts and status='completed', replay the stored response verbatim;
-- if 'in_progress', return 409 IDEMPOTENCY_IN_PROGRESS + Retry-After.
-- A reused key with a different request_hash is rejected (422).
-- ---------------------------------------------------------------------------
CREATE TABLE idempotency_keys (
    key             UUID NOT NULL,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    endpoint        VARCHAR(100) NOT NULL,          -- METHOD + path template
    request_hash    VARCHAR(64)  NOT NULL,          -- SHA-256 of canonical request body
    status          VARCHAR(20)  NOT NULL DEFAULT 'in_progress'
                        CHECK (status IN ('in_progress', 'completed')),
    response_code   SMALLINT,
    response_body   JSONB,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,

    PRIMARY KEY (key, user_id)                       -- key is scoped per user
);

CREATE INDEX idx_idem_gc ON idempotency_keys(created_at);  -- daily GC of >7d completed rows

-- ---------------------------------------------------------------------------
-- 5. service_categories
-- Registry of service verticals (medical, barber, mechanic …)
-- ---------------------------------------------------------------------------
CREATE TABLE service_categories (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug            service_category NOT NULL UNIQUE,
    display_name    VARCHAR(100) NOT NULL,
    description     TEXT,
    icon_key        TEXT,                  -- Supabase Storage key for category icon
    is_active       BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order      SMALLINT NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_service_categories_updated_at
    BEFORE UPDATE ON service_categories
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 6. feature_flags
-- Platform-wide feature flags (also cached in Redis)
-- ---------------------------------------------------------------------------
CREATE TABLE feature_flags (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key             VARCHAR(100) NOT NULL UNIQUE,
    description     TEXT,
    is_enabled      BOOLEAN NOT NULL DEFAULT FALSE,
    rollout_pct     SMALLINT NOT NULL DEFAULT 0 CHECK (rollout_pct BETWEEN 0 AND 100),
    allowed_roles   user_role[],           -- NULL = all roles
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_feature_flags_updated_at
    BEFORE UPDATE ON feature_flags
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 7. audit_log
-- Append-only. Tracks every write on sensitive tables.
-- ---------------------------------------------------------------------------
CREATE TABLE audit_log (
    id              BIGSERIAL PRIMARY KEY,  -- BIGSERIAL ok here (internal only, never exposed)
    actor_id        UUID REFERENCES users(id) ON DELETE SET NULL,
    table_name      VARCHAR(100) NOT NULL,
    record_id       UUID NOT NULL,
    action          VARCHAR(10) NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    before_state    JSONB,
    after_state     JSONB,
    ip_address      INET,
    user_agent      TEXT,
    -- Tamper-evidence chain: each row's row_hash = SHA-256 of the canonical
    -- concatenation of (prev_row_hash, id, actor_id, table_name, record_id,
    -- action, before_state, after_state, ip_address, user_agent, created_at).
    -- Computed by the `audit_log_chain()` BEFORE INSERT trigger below.
    -- A periodic job (RB-17) reads blocks of rows, re-verifies the chain, and
    -- signs the block head hash to an S3 Object-Lock bucket (WORM, 7-year
    -- retention). This makes silent tampering detectable even if a DB admin
    -- bypasses the triggers.
    prev_row_hash   BYTEA,
    row_hash        BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

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
-- ============================================================
-- LAYER 2: NOTIFICATIONS
-- ============================================================
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 8. notification_templates
-- ---------------------------------------------------------------------------
CREATE TABLE notification_templates (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key             VARCHAR(100) NOT NULL UNIQUE,  -- e.g. 'appointment.confirmed'
    channel         notification_channel NOT NULL,
    language        VARCHAR(10) NOT NULL DEFAULT 'en',
    subject         TEXT,                           -- email only
    body_template   TEXT NOT NULL,                  -- mustache/jinja template
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (key, channel, language)
);

CREATE TRIGGER trg_notification_templates_updated_at
    BEFORE UPDATE ON notification_templates
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 9. notification_log
-- Every dispatch attempt — one row per channel per recipient per event.
-- ---------------------------------------------------------------------------
CREATE TABLE notification_log (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    template_key        VARCHAR(100) NOT NULL,
    channel             notification_channel NOT NULL,
    status              notification_status NOT NULL DEFAULT 'pending',
    payload             JSONB NOT NULL DEFAULT '{}',  -- rendered body, subject, etc.
    provider_message_id TEXT,                         -- FCM/Termii/SendGrid message ID
    error_message       TEXT,
    sent_at             TIMESTAMPTZ,
    delivered_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_notification_log_updated_at
    BEFORE UPDATE ON notification_log
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 10. notification_preferences
-- Per-user, per-channel, per-event-category opt-in/out
-- ---------------------------------------------------------------------------
CREATE TABLE notification_preferences (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    event_category  VARCHAR(100) NOT NULL,  -- e.g. 'appointment_reminders', 'marketing'
    channel         notification_channel NOT NULL,
    is_enabled      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (user_id, event_category, channel)
);

CREATE TRIGGER trg_notification_preferences_updated_at
    BEFORE UPDATE ON notification_preferences
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- ============================================================
-- LAYER 3: PAYMENTS
-- ============================================================
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 11. payment_transactions
-- One row per payment attempt. Linked to appointment at booking time.
-- ---------------------------------------------------------------------------
CREATE TABLE payment_transactions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payer_id            UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    appointment_id      UUID,             -- FK added after appointments table is created
    provider            payment_provider NOT NULL,
    provider_reference  VARCHAR(255) UNIQUE,  -- Paystack reference / Stripe PaymentIntent ID
    amount              INTEGER NOT NULL CHECK (amount >= 0),  -- minor units
    currency_code       VARCHAR(3) NOT NULL DEFAULT 'GHS',     -- ISO 4217
    status              payment_status NOT NULL DEFAULT 'pending',
    provider_response   JSONB NOT NULL DEFAULT '{}',           -- full provider webhook payload
    refunded_amount     INTEGER NOT NULL DEFAULT 0 CHECK (refunded_amount >= 0),
    refund_reason       TEXT,
    captured_at         TIMESTAMPTZ,
    failed_at           TIMESTAMPTZ,
    refunded_at         TIMESTAMPTZ,
    -- Soft delete
    deleted_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT refund_lte_amount CHECK (refunded_amount <= amount)
);

CREATE TRIGGER trg_payment_transactions_updated_at
    BEFORE UPDATE ON payment_transactions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 12. payouts
-- Doctor earnings payouts (weekly batch via Paystack Transfer)
-- ---------------------------------------------------------------------------
CREATE TABLE payouts (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_id        UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    provider            payment_provider NOT NULL DEFAULT 'paystack',
    provider_reference  VARCHAR(255) UNIQUE,
    gross_amount        INTEGER NOT NULL CHECK (gross_amount >= 0),
    platform_fee        INTEGER NOT NULL DEFAULT 0 CHECK (platform_fee >= 0),
    -- Ghana withholding tax on professional services. Computed at payout
    -- time from current GRA rate (rate stored in platform_settings) and
    -- recipient's tax status (VAT-registered doctors get a different rate).
    -- Stored separately so the monthly WHT remittance report can aggregate
    -- across payouts without re-deriving. See legal/compliance §Tax.
    tax_withheld_minor  INTEGER NOT NULL DEFAULT 0 CHECK (tax_withheld_minor >= 0),
    tax_rate_bps        SMALLINT NOT NULL DEFAULT 0 CHECK (tax_rate_bps BETWEEN 0 AND 2500),  -- basis points, e.g. 750 = 7.5%
    net_amount          INTEGER NOT NULL CHECK (net_amount >= 0),
    currency_code       VARCHAR(3) NOT NULL DEFAULT 'GHS',
    status              payout_status NOT NULL DEFAULT 'pending',
    period_start        DATE NOT NULL,
    period_end          DATE NOT NULL,
    appointment_ids     UUID[] NOT NULL DEFAULT '{}',  -- appointments included in this payout
    provider_response   JSONB NOT NULL DEFAULT '{}',
    processed_at        TIMESTAMPTZ,
    failed_at           TIMESTAMPTZ,
    failure_reason      TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT payout_net_check CHECK (net_amount = gross_amount - platform_fee - tax_withheld_minor),
    CONSTRAINT payout_period_check CHECK (period_end > period_start)
);

CREATE TRIGGER trg_payouts_updated_at
    BEFORE UPDATE ON payouts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 13. bank_accounts
-- Doctor/clinic bank account details for payout
-- ---------------------------------------------------------------------------
CREATE TABLE bank_accounts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    bank_name       VARCHAR(200) NOT NULL,
    bank_code       VARCHAR(20),             -- Paystack bank code
    account_number  VARCHAR(50) NOT NULL,    -- encrypted at application level
    account_name    VARCHAR(200) NOT NULL,
    is_verified     BOOLEAN NOT NULL DEFAULT FALSE,
    is_primary      BOOLEAN NOT NULL DEFAULT FALSE,
    currency_code   VARCHAR(3) NOT NULL DEFAULT 'GHS',
    deleted_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_bank_accounts_updated_at
    BEFORE UPDATE ON bank_accounts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- ============================================================
-- LAYER 4: DOCTOR BOOKING VERTICAL
-- ============================================================
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 14. patient_profiles
-- Extended data for users with role = 'patient'
-- ---------------------------------------------------------------------------
CREATE TABLE patient_profiles (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    blood_group         VARCHAR(5),              -- e.g. 'O+', 'AB-'
    genotype            VARCHAR(5),              -- e.g. 'AA', 'AS', 'SS'
    height_cm           NUMERIC(5,1),
    weight_kg           NUMERIC(5,1),
    allergies           TEXT[],                  -- free-text allergy entries
    chronic_conditions  TEXT[],                  -- e.g. 'hypertension', 'diabetes'
    emergency_contact_name      VARCHAR(200),
    emergency_contact_phone     VARCHAR(20),
    emergency_contact_relation  VARCHAR(100),
    insurance_provider  VARCHAR(200),
    insurance_number    VARCHAR(100),
    -- Per-patient encryption: HKDF(HEALTH_RECORD_MASTER_KEY, salt=patient_key_salt)
    -- produces the AES-256 key used for this patient's timeline entries. Salt is
    -- generated once at patient_profile creation. Rotating the master key re-derives
    -- all per-patient keys on the fly during RB-05 rotation.
    patient_key_salt    BYTEA NOT NULL DEFAULT gen_random_bytes(32),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_patient_profiles_updated_at
    BEFORE UPDATE ON patient_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 15. specializations
-- Seeded taxonomy of medical specializations
-- ---------------------------------------------------------------------------
CREATE TABLE specializations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(200) NOT NULL UNIQUE,
    slug            VARCHAR(200) NOT NULL UNIQUE,
    parent_id       UUID REFERENCES specializations(id),  -- e.g. 'Internal Medicine' → 'Cardiology'
    description     TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    sort_order      SMALLINT NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_specializations_updated_at
    BEFORE UPDATE ON specializations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 16. clinics
-- Physical or virtual clinic entities
-- ---------------------------------------------------------------------------
CREATE TABLE clinics (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                VARCHAR(300) NOT NULL,
    slug                VARCHAR(300) NOT NULL UNIQUE,
    description         TEXT,
    address_line1       VARCHAR(300),
    address_line2       VARCHAR(300),
    city                VARCHAR(100),
    region              VARCHAR(100),
    country_code        VARCHAR(2) NOT NULL DEFAULT 'GH',
    timezone            VARCHAR(60) NOT NULL DEFAULT 'Africa/Accra',  -- IANA tz; governs slot start_at (ADR-0004)
    postal_code         VARCHAR(20),
    location            GEOGRAPHY(POINT, 4326),  -- PostGIS point (lng, lat)
    phone               VARCHAR(20),
    email               VARCHAR(320),
    website             VARCHAR(500),
    logo_storage_key    TEXT,
    photos_storage_keys TEXT[],
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    verification_status verification_status NOT NULL DEFAULT 'unverified',
    created_by          UUID REFERENCES users(id) ON DELETE SET NULL,
    deleted_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_clinics_updated_at
    BEFORE UPDATE ON clinics
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 17. doctor_profiles
-- Extended data for users with role = 'doctor'
-- ---------------------------------------------------------------------------
CREATE TABLE doctor_profiles (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                     UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    bio                         TEXT,
    years_of_experience         SMALLINT CHECK (years_of_experience >= 0),
    license_number              VARCHAR(100),
    license_issuing_council     VARCHAR(200),   -- e.g. 'Ghana Medical and Dental Council'
    license_expiry_date         DATE,
    license_storage_key         TEXT,           -- uploaded scan storage key
    verification_status         verification_status NOT NULL DEFAULT 'unverified',
    verified_at                 TIMESTAMPTZ,
    verified_by                 UUID REFERENCES users(id) ON DELETE SET NULL,
    rejection_reason            TEXT,
    -- Ratings (denormalized for fast read)
    rating_avg                  NUMERIC(3,2) NOT NULL DEFAULT 0.00 CHECK (rating_avg BETWEEN 0 AND 5),
    rating_count                INTEGER NOT NULL DEFAULT 0 CHECK (rating_count >= 0),
    rating_punctuality_avg      NUMERIC(3,2) NOT NULL DEFAULT 0.00,
    rating_communication_avg    NUMERIC(3,2) NOT NULL DEFAULT 0.00,
    rating_medical_avg          NUMERIC(3,2) NOT NULL DEFAULT 0.00,
    -- Discovery signals
    profile_completeness_pct    SMALLINT NOT NULL DEFAULT 0 CHECK (profile_completeness_pct BETWEEN 0 AND 100),
    response_rate_pct           SMALLINT NOT NULL DEFAULT 100 CHECK (response_rate_pct BETWEEN 0 AND 100),
    slot_confidence_score       NUMERIC(3,2) NOT NULL DEFAULT 1.00 CHECK (slot_confidence_score BETWEEN 0 AND 1),
    profile_views               INTEGER NOT NULL DEFAULT 0,
    -- Availability
    accepts_new_patients        BOOLEAN NOT NULL DEFAULT TRUE,
    is_profile_active           BOOLEAN NOT NULL DEFAULT TRUE,
    -- Embedding for semantic search (pgvector).
    -- profile_embedding dimension depends on embedding_model; the Celery
    -- regeneration pipeline refuses to write a vector whose dimension does
    -- not match the configured model. A model swap rebuilds the ivfflat
    -- index (see implementation plan §Part 5 — Embedding Pipeline).
    profile_embedding           VECTOR(1536),
    embedding_model             VARCHAR(64) NOT NULL DEFAULT 'text-embedding-3-small',
    embedding_content_hash      VARCHAR(64),    -- SHA-256 of the builder input (skip regen if unchanged)
    embedding_updated_at        TIMESTAMPTZ,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_doctor_profiles_updated_at
    BEFORE UPDATE ON doctor_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 18. doctor_specializations
-- Many-to-many: doctor ↔ specialization (with primary flag)
-- ---------------------------------------------------------------------------
CREATE TABLE doctor_specializations (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    doctor_profile_id   UUID NOT NULL REFERENCES doctor_profiles(id) ON DELETE CASCADE,
    specialization_id   UUID NOT NULL REFERENCES specializations(id) ON DELETE RESTRICT,
    is_primary          BOOLEAN NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (doctor_profile_id, specialization_id)
);

-- ---------------------------------------------------------------------------
-- 19. doctor_languages
-- Languages a doctor consults in
-- ---------------------------------------------------------------------------
CREATE TABLE doctor_languages (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    doctor_profile_id   UUID NOT NULL REFERENCES doctor_profiles(id) ON DELETE CASCADE,
    language_code       VARCHAR(10) NOT NULL,  -- BCP 47 e.g. 'en', 'tw', 'ak', 'ee'
    proficiency         VARCHAR(20) NOT NULL DEFAULT 'fluent'
                            CHECK (proficiency IN ('basic', 'conversational', 'fluent', 'native')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (doctor_profile_id, language_code)
);

-- ---------------------------------------------------------------------------
-- 20. doctor_qualifications
-- Educational and training credentials
-- ---------------------------------------------------------------------------
CREATE TABLE doctor_qualifications (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    doctor_profile_id   UUID NOT NULL REFERENCES doctor_profiles(id) ON DELETE CASCADE,
    degree              VARCHAR(200) NOT NULL,   -- e.g. 'MBChB', 'MD', 'FGCP'
    institution         VARCHAR(300) NOT NULL,
    country_code        VARCHAR(2) NOT NULL DEFAULT 'GH',
    year_obtained       SMALLINT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_doctor_qualifications_updated_at
    BEFORE UPDATE ON doctor_qualifications
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 21. clinic_affiliations
-- Doctor ↔ Clinic relationship with per-affiliation settings
-- ---------------------------------------------------------------------------
CREATE TABLE clinic_affiliations (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    doctor_profile_id           UUID NOT NULL REFERENCES doctor_profiles(id) ON DELETE CASCADE,
    clinic_id                   UUID NOT NULL REFERENCES clinics(id) ON DELETE CASCADE,
    consulting_room             VARCHAR(100),       -- e.g. 'Room 4B'
    is_primary_clinic           BOOLEAN NOT NULL DEFAULT FALSE,
    consultation_fee            INTEGER NOT NULL CHECK (consultation_fee >= 0),  -- minor units
    currency_code               VARCHAR(3) NOT NULL DEFAULT 'GHS',
    telehealth_fee              INTEGER CHECK (telehealth_fee >= 0),
    -- Refund policy: hours before slot start where patient cancellation still yields full refund.
    -- Consumed by appointment state machine T5 (cancelled_by_patient). Default 24h.
    cancellation_free_window_hours  SMALLINT NOT NULL DEFAULT 24
                                    CHECK (cancellation_free_window_hours BETWEEN 0 AND 168),
    is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
    started_at                  DATE,
    ended_at                    DATE,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (doctor_profile_id, clinic_id)
);

CREATE TRIGGER trg_clinic_affiliations_updated_at
    BEFORE UPDATE ON clinic_affiliations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 22. availability_templates
-- Weekly recurring availability rules per doctor per clinic
-- ---------------------------------------------------------------------------
CREATE TABLE availability_templates (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    doctor_profile_id       UUID NOT NULL REFERENCES doctor_profiles(id) ON DELETE CASCADE,
    clinic_affiliation_id   UUID REFERENCES clinic_affiliations(id) ON DELETE SET NULL,
    day_of_week             day_of_week NOT NULL,
    start_time              TIME NOT NULL,
    end_time                TIME NOT NULL,
    slot_duration_minutes   SMALLINT NOT NULL DEFAULT 30
                                CHECK (slot_duration_minutes IN (15, 20, 30, 45, 60)),
    booking_mode            booking_mode NOT NULL DEFAULT 'either',
    buffer_minutes          SMALLINT NOT NULL DEFAULT 0 CHECK (buffer_minutes >= 0),  -- gap between slots
    max_patients_per_slot   SMALLINT NOT NULL DEFAULT 1 CHECK (max_patients_per_slot >= 1),
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    effective_from          DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_until         DATE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT template_time_check CHECK (end_time > start_time),
    CONSTRAINT template_effective_check CHECK (
        effective_until IS NULL OR effective_until > effective_from
    )
);

CREATE TRIGGER trg_availability_templates_updated_at
    BEFORE UPDATE ON availability_templates
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 23. slots
-- Generated from availability_templates (by nightly Celery task, 60 days out)
-- One row = one bookable time slot on a specific date
-- ---------------------------------------------------------------------------
CREATE TABLE slots (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    doctor_profile_id       UUID NOT NULL REFERENCES doctor_profiles(id) ON DELETE CASCADE,
    clinic_affiliation_id   UUID REFERENCES clinic_affiliations(id) ON DELETE SET NULL,
    template_id             UUID REFERENCES availability_templates(id) ON DELETE SET NULL,
    slot_date               DATE NOT NULL,        -- local wall-clock date (display, filtering, uniqueness)
    start_time              TIME NOT NULL,        -- local wall-clock start
    end_time                TIME NOT NULL,        -- local wall-clock end
    -- Authoritative absolute instants for ALL slot time math (ADR-0004). Written once by the
    -- slot generation task from the governing IANA zone: the clinic's timezone for in-person
    -- slots, else the doctor's users.timezone for telehealth-only slots. Every gate/guard
    -- (v_appointments_safe telehealth window, T3 start guard, reminder ETAs, no-show sweep)
    -- compares start_at/end_at as timestamptz — never reconstructs an instant from
    -- slot_date + start_time (which is tz-naive and only correct at UTC+0).
    start_at                TIMESTAMPTZ NOT NULL,
    end_at                  TIMESTAMPTZ NOT NULL,
    booking_mode            booking_mode NOT NULL,
    status                  slot_status NOT NULL DEFAULT 'available',
    confidence_score        NUMERIC(3,2) NOT NULL DEFAULT 1.00 CHECK (confidence_score BETWEEN 0 AND 1),
    block_reason            TEXT,               -- if status = 'blocked', why
    blocked_by              UUID REFERENCES users(id) ON DELETE SET NULL,
    blocked_at              TIMESTAMPTZ,
    reserved_at             TIMESTAMPTZ,        -- when status moved to 'reserved'
    reservation_expires_at  TIMESTAMPTZ,        -- reservation TTL (10 minutes)
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT slot_time_check CHECK (end_time > start_time),
    CONSTRAINT slot_instant_check CHECK (end_at > start_at),
    UNIQUE (doctor_profile_id, slot_date, start_time)  -- prevent duplicate slots
);

CREATE TRIGGER trg_slots_updated_at
    BEFORE UPDATE ON slots
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 24. pre_consultation_form_templates
-- Doctor-defined form schemas (JSONB field definitions)
-- ---------------------------------------------------------------------------
CREATE TABLE pre_consultation_form_templates (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    doctor_profile_id   UUID NOT NULL REFERENCES doctor_profiles(id) ON DELETE CASCADE,
    name                VARCHAR(200) NOT NULL,
    description         TEXT,
    fields              JSONB NOT NULL DEFAULT '[]',
    -- fields schema: [{id, label, type, required, options, conditional_on_field_id, conditional_on_value}]
    -- types: 'text' | 'textarea' | 'select' | 'multi_select' | 'boolean' | 'number' | 'date' | 'file'
    is_default          BOOLEAN NOT NULL DEFAULT FALSE,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    version             SMALLINT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_pre_consultation_form_templates_updated_at
    BEFORE UPDATE ON pre_consultation_form_templates
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 25. appointments
-- The core booking record. One row per confirmed booking.
-- ---------------------------------------------------------------------------
CREATE TABLE appointments (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slot_id                     UUID NOT NULL REFERENCES slots(id) ON DELETE RESTRICT,
    patient_id                  UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    doctor_profile_id           UUID NOT NULL REFERENCES doctor_profiles(id) ON DELETE RESTRICT,
    clinic_affiliation_id       UUID REFERENCES clinic_affiliations(id) ON DELETE SET NULL,
    status                      appointment_status NOT NULL DEFAULT 'requested',
    booking_mode                booking_mode NOT NULL,
    -- Financial
    consultation_fee            INTEGER NOT NULL CHECK (consultation_fee >= 0),
    currency_code               VARCHAR(3) NOT NULL DEFAULT 'GHS',
    platform_fee_pct            NUMERIC(5,2) NOT NULL DEFAULT 8.00,
    payment_transaction_id      UUID REFERENCES payment_transactions(id) ON DELETE SET NULL,
    -- Pre-consultation
    form_template_id            UUID REFERENCES pre_consultation_form_templates(id) ON DELETE SET NULL,
    pre_consultation_responses  JSONB NOT NULL DEFAULT '{}',  -- patient's answers to form fields
    patient_notes               TEXT,                         -- freeform notes from patient
    -- Timing
    estimated_wait_minutes      SMALLINT DEFAULT 0,
    actual_start_time           TIMESTAMPTZ,
    actual_end_time             TIMESTAMPTZ,
    -- Telehealth
    telehealth_room_id          VARCHAR(255),    -- Daily.co room name
    telehealth_room_url         TEXT,            -- Doctor URL (contains token)
    telehealth_patient_url      TEXT,            -- Patient URL (contains token)
    telehealth_room_expires_at  TIMESTAMPTZ,
    -- Cancellation
    cancelled_at                TIMESTAMPTZ,
    cancellation_reason         TEXT,
    cancelled_by                UUID REFERENCES users(id) ON DELETE SET NULL,
    -- No-show
    no_show_marked_at           TIMESTAMPTZ,
    no_show_marked_by           UUID REFERENCES users(id) ON DELETE SET NULL,
    -- Follow-up
    follow_up_recommended       BOOLEAN,
    follow_up_notes             TEXT,
    follow_up_appointment_id    UUID REFERENCES appointments(id) ON DELETE SET NULL,
    -- Soft delete
    deleted_at                  TIMESTAMPTZ,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_appointments_updated_at
    BEFORE UPDATE ON appointments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Add deferred FK from payment_transactions → appointments
ALTER TABLE payment_transactions
    ADD CONSTRAINT fk_payment_appointment
    FOREIGN KEY (appointment_id) REFERENCES appointments(id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------------
-- 26. appointment_status_history
-- Immutable log of every status transition on an appointment
-- ---------------------------------------------------------------------------
CREATE TABLE appointment_status_history (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    appointment_id  UUID NOT NULL REFERENCES appointments(id) ON DELETE CASCADE,
    from_status     appointment_status,          -- NULL for first entry
    to_status       appointment_status NOT NULL,
    actor_id        UUID REFERENCES users(id) ON DELETE SET NULL,
    reason          TEXT,
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- 27. health_timeline_entries
-- Encrypted at rest (content column). AES-256 at application level.
-- ---------------------------------------------------------------------------
CREATE TABLE health_timeline_entries (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id          UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    appointment_id      UUID REFERENCES appointments(id) ON DELETE SET NULL,
    authored_by         UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    entry_type          timeline_entry_type NOT NULL,
    title               VARCHAR(500),
    content_encrypted   BYTEA NOT NULL,          -- AES-256-GCM ciphertext of JSONB payload
    content_iv          BYTEA NOT NULL,          -- random 96-bit GCM nonce, unique per entry (never derived from content)
    -- Which HEALTH_RECORD_MASTER_KEY version encrypted this row. Required so the
    -- RB-05 rotation job can run online/resumably: it re-encrypts rows where
    -- key_version < current and bumps this column, and a partial rotation is
    -- always recoverable because each row records the key it was sealed with.
    key_version         SMALLINT NOT NULL DEFAULT 1,
    visibility          timeline_visibility NOT NULL DEFAULT 'patient_only',
    attachment_keys     TEXT[] NOT NULL DEFAULT '{}',  -- Supabase Storage keys
    icd10_codes         VARCHAR(10)[],           -- for diagnosis_note entries
    is_pinned           BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_health_timeline_entries_updated_at
    BEFORE UPDATE ON health_timeline_entries
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 27b. consent_terms_acceptances
-- DPA 2012 consent evidence: user acceptance of terms/privacy/marketing/analytics
-- DO NOT CONFUSE with consent_grants (patient → doctor timeline access).
-- ---------------------------------------------------------------------------
CREATE TABLE consent_terms_acceptances (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    consent_type    VARCHAR(100) NOT NULL
                        CHECK (consent_type IN (
                            'terms_of_service', 'privacy_notice',
                            'health_profile', 'health_timeline',
                            'marketing', 'analytics'
                        )),
    version         VARCHAR(20) NOT NULL,     -- privacy notice version e.g. '1.2'
    granted         BOOLEAN NOT NULL,
    granted_at      TIMESTAMPTZ,
    withdrawn_at    TIMESTAMPTZ,
    ip_address      INET,
    user_agent      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (user_id, consent_type, version)
);

-- ---------------------------------------------------------------------------
-- 28. consent_grants
-- Patient consent for doctors to read their timeline
-- ---------------------------------------------------------------------------
CREATE TABLE consent_grants (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    granted_to_doctor   UUID NOT NULL REFERENCES doctor_profiles(id) ON DELETE CASCADE,
    scope               consent_scope NOT NULL DEFAULT 'read_timeline',
    granted_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at          TIMESTAMPTZ,
    revoked_at          TIMESTAMPTZ,
    revoke_reason       TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (patient_id, granted_to_doctor, scope)
);

CREATE TRIGGER trg_consent_grants_updated_at
    BEFORE UPDATE ON consent_grants
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 29. saved_doctors
-- Patient's saved / favourite doctors (offline-syncable)
-- ---------------------------------------------------------------------------
CREATE TABLE saved_doctors (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    doctor_profile_id   UUID NOT NULL REFERENCES doctor_profiles(id) ON DELETE CASCADE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (patient_id, doctor_profile_id)
);

-- ---------------------------------------------------------------------------
-- 30. reviews
-- Post-appointment structured ratings
-- ---------------------------------------------------------------------------
CREATE TABLE reviews (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    appointment_id          UUID NOT NULL UNIQUE REFERENCES appointments(id) ON DELETE RESTRICT,
    patient_id              UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    doctor_profile_id       UUID NOT NULL REFERENCES doctor_profiles(id) ON DELETE RESTRICT,
    rating_overall          SMALLINT NOT NULL CHECK (rating_overall BETWEEN 1 AND 5),
    rating_punctuality      SMALLINT NOT NULL CHECK (rating_punctuality BETWEEN 1 AND 5),
    rating_communication    SMALLINT NOT NULL CHECK (rating_communication BETWEEN 1 AND 5),
    rating_medical          SMALLINT NOT NULL CHECK (rating_medical BETWEEN 1 AND 5),
    review_text             TEXT,
    doctor_reply            TEXT,
    doctor_replied_at       TIMESTAMPTZ,
    status                  review_status NOT NULL DEFAULT 'pending',
    flag_reason             TEXT,
    is_anonymous            BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at              TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_reviews_updated_at
    BEFORE UPDATE ON reviews
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 31. documents
-- KYC and patient documents stored in Supabase Storage
-- ---------------------------------------------------------------------------
CREATE TABLE documents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    document_type   document_type NOT NULL,
    storage_key     TEXT NOT NULL,              -- Supabase Storage key (signed URL on access)
    file_name       VARCHAR(500),
    mime_type       VARCHAR(100),
    file_size_bytes INTEGER,
    is_verified     BOOLEAN NOT NULL DEFAULT FALSE,
    verified_by     UUID REFERENCES users(id) ON DELETE SET NULL,
    verified_at     TIMESTAMPTZ,
    rejection_reason TEXT,
    expires_at      TIMESTAMPTZ,               -- for licenses with expiry
    -- Malware scan state: uploads land in the `quarantine` bucket with
    -- scan_status='pending'; the scan worker promotes to 'clean' (moves to
    -- primary bucket) or 'infected' (keeps in quarantine, notifies SOC).
    -- Signed URLs MUST only be issued when scan_status = 'clean'.
    scan_status     VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (scan_status IN ('pending', 'clean', 'infected', 'error')),
    scan_result     JSONB,                     -- {engine, signature, scanned_at, ...}
    scanned_at      TIMESTAMPTZ,
    deleted_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_documents_updated_at
    BEFORE UPDATE ON documents
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 32. telehealth_sessions
-- Log of Daily.co room sessions (separate from appointment for analytics)
-- ---------------------------------------------------------------------------
CREATE TABLE telehealth_sessions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    appointment_id      UUID NOT NULL UNIQUE REFERENCES appointments(id) ON DELETE CASCADE,
    provider            VARCHAR(50) NOT NULL DEFAULT 'daily.co',
    room_name           VARCHAR(255) NOT NULL,
    room_url            TEXT NOT NULL,
    doctor_joined_at    TIMESTAMPTZ,
    patient_joined_at   TIMESTAMPTZ,
    ended_at            TIMESTAMPTZ,
    duration_seconds    INTEGER,
    quality_score       NUMERIC(3,2),           -- reported by Daily.co
    provider_session_id VARCHAR(255),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_telehealth_sessions_updated_at
    BEFORE UPDATE ON telehealth_sessions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- ============================================================
-- INDEXES
-- ============================================================
-- ---------------------------------------------------------------------------

-- users
CREATE INDEX idx_users_email         ON users(email) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_phone         ON users(phone) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_role          ON users(role) WHERE deleted_at IS NULL;

-- device_tokens
CREATE INDEX idx_device_tokens_user  ON device_tokens(user_id) WHERE is_active = TRUE;

-- refresh_token_blocklist
CREATE INDEX idx_rtb_expires         ON refresh_token_blocklist(expires_at);

-- notification_log
CREATE INDEX idx_notif_log_recipient ON notification_log(recipient_id, created_at DESC);
CREATE INDEX idx_notif_log_status    ON notification_log(status) WHERE status = 'pending';

-- payment_transactions
CREATE INDEX idx_payments_payer      ON payment_transactions(payer_id, created_at DESC);
CREATE INDEX idx_payments_appt       ON payment_transactions(appointment_id);
CREATE INDEX idx_payments_status     ON payment_transactions(status);
CREATE INDEX idx_payments_ref        ON payment_transactions(provider_reference);

-- payouts
CREATE INDEX idx_payouts_recipient   ON payouts(recipient_id, created_at DESC);
CREATE INDEX idx_payouts_status      ON payouts(status);

-- doctor_profiles
CREATE INDEX idx_doctor_user         ON doctor_profiles(user_id);
CREATE INDEX idx_doctor_verified     ON doctor_profiles(verification_status) WHERE is_profile_active = TRUE;
CREATE INDEX idx_doctor_rating       ON doctor_profiles(rating_avg DESC) WHERE verification_status = 'verified';
CREATE INDEX idx_doctor_embedding    ON doctor_profiles USING ivfflat (profile_embedding vector_cosine_ops)
    WITH (lists = 100);

-- clinics
CREATE INDEX idx_clinics_location    ON clinics USING GIST(location);
CREATE INDEX idx_clinics_city        ON clinics(city) WHERE deleted_at IS NULL;

-- clinic_affiliations
CREATE INDEX idx_affil_doctor        ON clinic_affiliations(doctor_profile_id) WHERE is_active = TRUE;
CREATE INDEX idx_affil_clinic        ON clinic_affiliations(clinic_id) WHERE is_active = TRUE;

-- availability_templates
CREATE INDEX idx_avail_doctor_day    ON availability_templates(doctor_profile_id, day_of_week) WHERE is_active = TRUE;

-- slots
CREATE INDEX idx_slots_doctor_date   ON slots(doctor_profile_id, slot_date, start_time) WHERE status = 'available';
CREATE INDEX idx_slots_date_status   ON slots(slot_date, status);
CREATE INDEX idx_slots_reservation   ON slots(reservation_expires_at) WHERE status = 'reserved';
CREATE INDEX idx_slots_start_at      ON slots(start_at);  -- time-window queries: reminders, no-show sweep (ADR-0004)

-- appointments
CREATE INDEX idx_appt_patient        ON appointments(patient_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_appt_doctor         ON appointments(doctor_profile_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_appt_slot           ON appointments(slot_id);
CREATE INDEX idx_appt_status         ON appointments(status) WHERE deleted_at IS NULL;
CREATE INDEX idx_appt_status_history ON appointment_status_history(appointment_id, created_at DESC);

-- health_timeline_entries
CREATE INDEX idx_timeline_patient    ON health_timeline_entries(patient_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_timeline_appt       ON health_timeline_entries(appointment_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_timeline_type       ON health_timeline_entries(patient_id, entry_type) WHERE deleted_at IS NULL;

-- consent_grants
CREATE INDEX idx_consent_patient     ON consent_grants(patient_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_consent_doctor      ON consent_grants(granted_to_doctor) WHERE revoked_at IS NULL;

-- consent_terms_acceptances
CREATE INDEX idx_cta_user_type       ON consent_terms_acceptances(user_id, consent_type)
    WHERE withdrawn_at IS NULL;

-- reviews
CREATE INDEX idx_reviews_doctor      ON reviews(doctor_profile_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_reviews_patient     ON reviews(patient_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_reviews_status      ON reviews(status);

-- saved_doctors
CREATE INDEX idx_saved_patient       ON saved_doctors(patient_id);

-- documents
CREATE INDEX idx_docs_owner          ON documents(owner_id, document_type) WHERE deleted_at IS NULL;
-- Pending scans are the work queue for the ClamAV worker; partial index keeps it tight.
CREATE INDEX idx_docs_scan_pending   ON documents(created_at) WHERE scan_status = 'pending';

-- audit_log
CREATE INDEX idx_audit_table_record  ON audit_log(table_name, record_id, created_at DESC);
CREATE INDEX idx_audit_actor         ON audit_log(actor_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- ============================================================
-- ROW LEVEL SECURITY POLICIES
-- ============================================================
-- ---------------------------------------------------------------------------

ALTER TABLE users                           ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_auth_providers             ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_tokens                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_log                ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_preferences        ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_transactions            ENABLE ROW LEVEL SECURITY;
ALTER TABLE payouts                         ENABLE ROW LEVEL SECURITY;
ALTER TABLE bank_accounts                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE patient_profiles                ENABLE ROW LEVEL SECURITY;
ALTER TABLE doctor_profiles                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE doctor_specializations          ENABLE ROW LEVEL SECURITY;
ALTER TABLE doctor_languages                ENABLE ROW LEVEL SECURITY;
ALTER TABLE doctor_qualifications           ENABLE ROW LEVEL SECURITY;
ALTER TABLE clinic_affiliations             ENABLE ROW LEVEL SECURITY;
ALTER TABLE availability_templates          ENABLE ROW LEVEL SECURITY;
ALTER TABLE slots                           ENABLE ROW LEVEL SECURITY;
ALTER TABLE pre_consultation_form_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE appointments                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE appointment_status_history      ENABLE ROW LEVEL SECURITY;
ALTER TABLE health_timeline_entries         ENABLE ROW LEVEL SECURITY;
ALTER TABLE consent_grants                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE consent_terms_acceptances       ENABLE ROW LEVEL SECURITY;
ALTER TABLE saved_doctors                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE reviews                         ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents                       ENABLE ROW LEVEL SECURITY;
ALTER TABLE telehealth_sessions             ENABLE ROW LEVEL SECURITY;
-- idempotency_keys: RLS enabled with NO policy = deny-all for anon/authenticated.
-- Only the Django service role (which bypasses RLS) ever touches it.
ALTER TABLE idempotency_keys                ENABLE ROW LEVEL SECURITY;

-- =====================================================================
-- RLS policy conventions (hardened per ADR-0001):
--   * Every policy names its target Postgres role via TO (authenticated / anon).
--     `TO authenticated` ALONE is not authorisation — it is always paired with
--     an ownership predicate in USING.
--   * Every INSERT / UPDATE / ALL policy carries WITH CHECK, so a row can never
--     be reassigned to another user (Supabase BOLA/IDOR trap: without WITH CHECK
--     an UPDATE can rewrite the owning id).
--   * auth.uid() is wrapped as (SELECT auth.uid()) so the planner evaluates it
--     once per statement instead of once per row.
--   * The application role (patient/doctor/clinic_admin/platform_admin) is NEVER
--     trusted from a token claim here; it is re-read server-side. These policies
--     assert row OWNERSHIP only. The client-facing JWT's `role` claim is always
--     'authenticated' (see ADR-0001); the app role travels in a separate claim.
-- =====================================================================

-- ---- users ----
CREATE POLICY "users_read_own"
    ON users FOR SELECT TO authenticated
    USING ((SELECT auth.uid()) = id);

CREATE POLICY "users_update_own"
    ON users FOR UPDATE TO authenticated
    USING ((SELECT auth.uid()) = id)
    WITH CHECK ((SELECT auth.uid()) = id);

-- ---- patient_profiles ----
CREATE POLICY "patient_profile_own"
    ON patient_profiles FOR ALL TO authenticated
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));

-- ---- doctor_profiles: verified profiles are publicly readable ----
CREATE POLICY "doctor_profile_public_read"
    ON doctor_profiles FOR SELECT TO anon, authenticated
    USING (verification_status = 'verified' AND is_profile_active = TRUE);

CREATE POLICY "doctor_profile_own_all"
    ON doctor_profiles FOR ALL TO authenticated
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));

-- ---- slots: available slots are publicly readable ----
CREATE POLICY "slots_public_read"
    ON slots FOR SELECT TO anon, authenticated
    USING (status = 'available' AND slot_date >= CURRENT_DATE);

CREATE POLICY "slots_doctor_own"
    ON slots FOR ALL TO authenticated
    USING (
        doctor_profile_id IN (
            SELECT id FROM doctor_profiles WHERE user_id = (SELECT auth.uid())
        )
    )
    WITH CHECK (
        doctor_profile_id IN (
            SELECT id FROM doctor_profiles WHERE user_id = (SELECT auth.uid())
        )
    );

-- ---- appointments ----
-- Clients read appointments ONLY through v_appointments_safe (below); direct
-- SELECT on this raw table is REVOKED from authenticated/anon (see the
-- GRANT/REVOKE block after the policies), so the telehealth URL time-gate can
-- never be bypassed. These policies remain as defence in depth. All writes go
-- through Django (service role, which bypasses RLS).
CREATE POLICY "appointments_patient_read"
    ON appointments FOR SELECT TO authenticated
    USING (patient_id = (SELECT auth.uid()));

CREATE POLICY "appointments_doctor_read"
    ON appointments FOR SELECT TO authenticated
    USING (
        doctor_profile_id IN (
            SELECT id FROM doctor_profiles WHERE user_id = (SELECT auth.uid())
        )
    );

-- View that nulls telehealth URLs until start_at - 15 min (absolute instant, ADR-0004).
-- This is the ONLY path Flutter + Next.js are allowed to read from.
-- The DRF serializer enforces the same gate on the Django path.
CREATE OR REPLACE VIEW v_appointments_safe
WITH (security_invoker = true) AS
SELECT
    a.id, a.slot_id, a.patient_id, a.doctor_profile_id, a.clinic_affiliation_id,
    a.status, a.booking_mode, a.consultation_fee, a.currency_code,
    a.platform_fee_pct, a.payment_transaction_id,
    a.form_template_id, a.pre_consultation_responses, a.patient_notes,
    a.estimated_wait_minutes, a.actual_start_time, a.actual_end_time,
    a.telehealth_room_id,
    -- URLs are hidden until 15 minutes before the slot start
    CASE
        WHEN s.start_at <= NOW() + INTERVAL '15 minutes'
            THEN a.telehealth_room_url
        ELSE NULL
    END AS telehealth_room_url,
    CASE
        WHEN s.start_at <= NOW() + INTERVAL '15 minutes'
            THEN a.telehealth_patient_url
        ELSE NULL
    END AS telehealth_patient_url,
    a.telehealth_room_expires_at,
    a.cancelled_at, a.cancellation_reason, a.cancelled_by,
    a.no_show_marked_at, a.no_show_marked_by,
    a.follow_up_recommended, a.follow_up_notes, a.follow_up_appointment_id,
    a.deleted_at, a.created_at, a.updated_at
FROM appointments a
JOIN slots s ON s.id = a.slot_id;

COMMENT ON VIEW v_appointments_safe IS
    'Client-facing view. Nulls telehealth URLs outside the 15-minute join window. '
    'Flutter and Next.js clients must read appointments only through this view; '
    'the raw appointments table is reserved for Django service-role writes.';

-- ---- health_timeline_entries: patient owns, doctor can read with consent ----
-- ADR-0003: this table is Django-only. Content is AES-256-GCM ciphertext under a
-- per-patient key only Django holds, so a direct client read is undecryptable AND
-- widens the PHI surface. Direct SELECT is REVOKED from authenticated/anon in the
-- GRANT/REVOKE block below. These policies stay as defence in depth for the
-- service-role path (which decrypts in memory and enforces consent in Django too).
CREATE POLICY "timeline_patient_own"
    ON health_timeline_entries FOR ALL TO authenticated
    USING (patient_id = (SELECT auth.uid()))
    WITH CHECK (patient_id = (SELECT auth.uid()));

CREATE POLICY "timeline_doctor_consent_read"
    ON health_timeline_entries FOR SELECT TO authenticated
    USING (
        visibility IN ('shared_with_current_doctor', 'shared_with_all_future_doctors')
        AND EXISTS (
            SELECT 1 FROM consent_grants cg
            JOIN doctor_profiles dp ON dp.id = cg.granted_to_doctor
            WHERE cg.patient_id = health_timeline_entries.patient_id
              AND dp.user_id = (SELECT auth.uid())
              AND cg.revoked_at IS NULL
              AND (cg.expires_at IS NULL OR cg.expires_at > NOW())
        )
    );

-- ---- payment_transactions: payer can read own ----
CREATE POLICY "payments_payer_read"
    ON payment_transactions FOR SELECT TO authenticated
    USING (payer_id = (SELECT auth.uid()));

-- ---- reviews: published reviews are publicly readable ----
CREATE POLICY "reviews_public_read"
    ON reviews FOR SELECT TO anon, authenticated
    USING (status = 'published' AND deleted_at IS NULL);

CREATE POLICY "reviews_patient_own"
    ON reviews FOR ALL TO authenticated
    USING (patient_id = (SELECT auth.uid()))
    WITH CHECK (patient_id = (SELECT auth.uid()));

-- ---- saved_doctors: patient owns ----
CREATE POLICY "saved_doctors_own"
    ON saved_doctors FOR ALL TO authenticated
    USING (patient_id = (SELECT auth.uid()))
    WITH CHECK (patient_id = (SELECT auth.uid()));

-- ---- consent_terms_acceptances: user manages own; append-only from DRF ----
CREATE POLICY "cta_own_read"
    ON consent_terms_acceptances FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));

CREATE POLICY "cta_own_insert"
    ON consent_terms_acceptances FOR INSERT TO authenticated
    WITH CHECK (user_id = (SELECT auth.uid()));

-- NOTE: no UPDATE or DELETE policy — withdrawals are represented by a new row
-- with granted = false or by setting withdrawn_at via a service-role-only path.

-- ---- consent_grants: patient manages own ----
CREATE POLICY "consent_patient_own"
    ON consent_grants FOR ALL TO authenticated
    USING (patient_id = (SELECT auth.uid()))
    WITH CHECK (patient_id = (SELECT auth.uid()));

CREATE POLICY "consent_doctor_read"
    ON consent_grants FOR SELECT TO authenticated
    USING (
        granted_to_doctor IN (
            SELECT id FROM doctor_profiles WHERE user_id = (SELECT auth.uid())
        )
    );

-- ---- documents: owner reads own ----
CREATE POLICY "documents_owner"
    ON documents FOR ALL TO authenticated
    USING (owner_id = (SELECT auth.uid()))
    WITH CHECK (owner_id = (SELECT auth.uid()));

-- ---- notification_preferences: user manages own ----
CREATE POLICY "notif_prefs_own"
    ON notification_preferences FOR ALL TO authenticated
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));

-- ---- telehealth_sessions ----
CREATE POLICY "telehealth_patient_read"
    ON telehealth_sessions FOR SELECT TO authenticated
    USING (
        appointment_id IN (
            SELECT id FROM appointments WHERE patient_id = (SELECT auth.uid())
        )
    );

CREATE POLICY "telehealth_doctor_read"
    ON telehealth_sessions FOR SELECT TO authenticated
    USING (
        appointment_id IN (
            SELECT id FROM appointments
            WHERE doctor_profile_id IN (
                SELECT id FROM doctor_profiles WHERE user_id = (SELECT auth.uid())
            )
        )
    );

-- ---- bank_accounts: user reads own ----
-- ADR-0003: Django-only (encrypted account number; API returns last-4 only).
-- Direct SELECT is REVOKED from authenticated/anon below.
CREATE POLICY "bank_accounts_own"
    ON bank_accounts FOR ALL TO authenticated
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));

-- ---------------------------------------------------------------------------
-- TABLE-LEVEL GRANTS / REVOKES (ADR-0001 + ADR-0003)
-- RLS decides which ROWS are visible; GRANT decides whether a role can touch the
-- TABLE at all. We revoke the raw appointments table (telehealth-URL gate lives
-- in the view) and the two Django-only PHI/financial tables, so no client token
-- can reach them even if a policy were misconfigured.
-- ---------------------------------------------------------------------------
REVOKE SELECT ON appointments             FROM anon, authenticated;
GRANT  SELECT ON v_appointments_safe      TO   authenticated;        -- URL-gated view is the only client path (auth users only)
REVOKE SELECT ON health_timeline_entries  FROM anon, authenticated;  -- Django-only; content is encrypted
REVOKE SELECT ON bank_accounts            FROM anon, authenticated;  -- Django-only; last-4 via API

-- ---------------------------------------------------------------------------
-- ============================================================
-- SEED DATA — Service Categories
-- ============================================================
-- ---------------------------------------------------------------------------
INSERT INTO service_categories (slug, display_name, description, is_active, sort_order) VALUES
    ('medical',   'Medical',   'Doctor and specialist consultations', TRUE,  1),
    ('barber',    'Barber',    'Haircuts and grooming services',      FALSE, 2),
    ('mechanic',  'Mechanic',  'Automobile repair and servicing',     FALSE, 3);

-- ---------------------------------------------------------------------------
-- ============================================================
-- SEED DATA — Feature Flags
-- ============================================================
-- ---------------------------------------------------------------------------
INSERT INTO feature_flags (key, description, is_enabled, rollout_pct) VALUES
    ('telehealth_enabled',           'Enable telehealth video consultations',       TRUE,  100),
    ('semantic_search_enabled',      'Enable embedding-based semantic search',      FALSE, 0),
    ('barber_vertical_enabled',      'Enable barber booking vertical',              FALSE, 0),
    ('mechanic_vertical_enabled',    'Enable mechanic booking vertical',            FALSE, 0),
    ('family_accounts_enabled',      'Enable family/dependent account management',  FALSE, 0),
    ('ai_appointment_brief_enabled', 'Enable AI pre-appointment brief for doctors', FALSE, 0),
    ('paystack_enabled',             'Enable Paystack payment provider',            TRUE,  100),
    ('stripe_enabled',               'Enable Stripe payment provider',              FALSE, 0);

-- ---------------------------------------------------------------------------
-- END OF Veridian SCHEMA DDL
-- ---------------------------------------------------------------------------

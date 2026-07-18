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
--
-- DEFINER-style on purpose (NOT security_invoker — empirical finding, 2026-07-17):
-- a security_invoker view executes with the CALLER's privileges, and the caller's
-- SELECT on the raw appointments table is REVOKED below — so an invoker view here
-- is unreadable by clients, on Supabase and plain Postgres alike. The view instead
-- runs as its owner (the migration role, which reads the base table) and EMBEDS the
-- row-ownership predicates that the appointments RLS policies express, so it can
-- never widen access: patients see own rows, doctors see their profile's rows,
-- anon sees nothing (auth.uid() IS NULL). security_barrier stops user-supplied
-- functions from leaking pre-filter rows via predicate pushdown.
CREATE OR REPLACE VIEW v_appointments_safe
WITH (security_barrier = true) AS
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
JOIN slots s ON s.id = a.slot_id
WHERE
    -- Mirrors appointments_patient_read + appointments_doctor_read: the definer
    -- view must scope rows itself because it does not run under the caller's RLS.
    a.patient_id = (SELECT auth.uid())
    OR a.doctor_profile_id IN (
        SELECT id FROM doctor_profiles WHERE user_id = (SELECT auth.uid())
    );

COMMENT ON VIEW v_appointments_safe IS
    'Client-facing view (definer-style, ownership predicates embedded). Nulls '
    'telehealth URLs outside the 15-minute join window. Flutter and Next.js '
    'clients must read appointments only through this view; the raw appointments '
    'table is reserved for Django service-role writes.';

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
REVOKE ALL    ON v_appointments_safe      FROM anon;                 -- hygiene: default privileges would otherwise grant it; predicate yields 0 rows for anon anyway
REVOKE SELECT ON health_timeline_entries  FROM anon, authenticated;  -- Django-only; content is encrypted
REVOKE SELECT ON bank_accounts            FROM anon, authenticated;  -- Django-only; last-4 via API

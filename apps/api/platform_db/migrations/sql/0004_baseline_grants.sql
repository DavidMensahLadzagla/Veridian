-- Supabase-baseline privilege emulation (ADR-0007 compat surface).
--
-- On Supabase, anon / authenticated / service_role hold blanket grants on the
-- public schema (that is the baseline the canonical REVOKE block subtracts
-- from). Plain Postgres has no such baseline, so without this the client roles
-- fail on table-level permission before any RLS policy is even evaluated —
-- and the test-DB could never exercise the policy layer.
--
-- Idempotent and harmless on Supabase (the grants already exist there).
-- MUST run after the model tables exist and BEFORE the RLS/REVOKE migration:
-- the REVOKEs subtract appointments / health_timeline_entries / bank_accounts
-- from this baseline, exactly as they do on Supabase.
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES    IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role;

-- Future tables created by this (migration) role inherit the same baseline,
-- mirroring Supabase's ALTER DEFAULT PRIVILEGES configuration.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;

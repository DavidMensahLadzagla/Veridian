-- Idempotent. On Supabase these objects already exist and are SKIPPED
-- (we never CREATE OR REPLACE auth.uid() — that would clobber the real one).
DO $shim$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
    END IF;
    -- service_role is what Django connects as in prod; it must bypass RLS so
    -- service-layer writes are never blocked by a client policy.
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
        CREATE ROLE service_role NOLOGIN BYPASSRLS;
    END IF;
END
$shim$;

DO $shim$
BEGIN
    IF NOT EXISTS (
        SELECT FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'auth' AND p.proname = 'uid'
    ) THEN
        CREATE SCHEMA IF NOT EXISTS auth;
        EXECUTE $fn$
            CREATE FUNCTION auth.uid() RETURNS uuid
            LANGUAGE sql STABLE
            AS $body$
                SELECT COALESCE(
                    NULLIF(current_setting('request.jwt.claim.sub', true), ''),
                    NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'sub'
                )::uuid
            $body$;
        $fn$;
        GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
        GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;
    END IF;
END
$shim$;

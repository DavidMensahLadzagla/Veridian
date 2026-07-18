# ADR-0007 — Supabase-compatibility shim: making the RLS/GRANT layer portable across Supabase, CI, and local Postgres

- **Status:** Accepted (2026-07-03). A single idempotent bootstrap migration provisions the
  Supabase-only objects (`anon` / `authenticated` / `service_role` roles, `auth` schema,
  `auth.uid()`) **only when absent**, so the ADR-0006 RLS/GRANT layer applies unchanged on
  Supabase, GitHub Actions Postgres, the Django test database, and local dev.
- **Date:** 2026-07-03
- **Deciders:** Lead engineer + project owner
- **Related:** ADR-0001 (Django-issued JWTs → `auth.uid()`), ADR-0006 (Django-migrations-canonical;
  RLS/triggers via `RunSQL`), `plans/veridian_schema.sql` (RLS policies + GRANT/REVOKE),
  `veridian-keystone-risks` (the auth-bridge finding this closes)

## Context

ADR-0006 makes Django migrations canonical and ships the RLS policies, `v_appointments_safe`,
and GRANT/REVOKE as `RunSQL` operations. ADR-0001 writes every policy as
`(SELECT auth.uid()) = <owner col>` and targets Postgres roles via `TO authenticated` / `TO anon`.

Those two decisions have an unstated dependency that only shows up **when the migrations run
somewhere that is not Supabase**:

- `auth.uid()` lives in Supabase's `auth` schema. It does **not** exist in a vanilla Postgres.
- `authenticated`, `anon`, and `service_role` are Supabase-provisioned roles. They do **not**
  exist in a vanilla Postgres.

CI (ADR-0006's own verification gate) runs `migrate` / `pytest` against a plain Postgres with
only PostGIS + pgvector added. Local dev and the Django test-DB are the same. So the moment
`migrate` reaches the RLS migration it aborts. **This was verified, not theorised** — running the
raw policy DDL against a clean Postgres 17 yields:

```
ERROR:  schema "auth" does not exist
ERROR:  role "authenticated" does not exist
```

Left unaddressed, the choices are all bad: make the RLS layer Supabase-only and apply it
out-of-band (reintroduces the dual-source drift ADR-0006 exists to kill), weaken/remove RLS in
non-prod (the test suite then never exercises the PHI-isolation layer), or fork the SQL per
environment (two texts of record). None are acceptable for a PHI platform.

## Decision

Ship **one idempotent bootstrap migration** — the *Supabase-compatibility shim* — that runs
before the RLS/GRANT layer and creates the Supabase-only objects **only if they are missing**:

1. Roles `anon`, `authenticated` (both `NOLOGIN`) and `service_role` (`NOLOGIN BYPASSRLS`),
   each guarded by `IF NOT EXISTS (SELECT FROM pg_roles …)`.
2. Schema `auth` + function `auth.uid()` returning the JWT `sub` claim from the
   `request.jwt.claims` GUC — mirroring Supabase's own implementation — plus `USAGE`/`EXECUTE`
   grants to the three roles. **This entire block is skipped when `auth.uid()` already exists**,
   so on Supabase we never touch (or clobber) the real `auth` schema, and never attempt a GRANT
   on a schema the Django role does not own.

On Supabase every object already exists → the shim is a no-op. On CI / local / the test-DB the
shim creates functional stand-ins, so the identical RLS layer applies **and** the test suite can
drive RLS by setting `request.jwt.claims` (proven below). One text of record, every environment.

Placement: the shim is the first operation of a dedicated **no-model app** (e.g. `platform_db`)
whose migrations also carry the extensions and the trigger/function/view RunSQL. A no-model app
is never touched by `makemigrations`, so these hand-authored RunSQL migrations are fully under
our control and `makemigrations --check` stays green. The shim migration is depended on by the
RLS migration (which references `auth.uid()` / the roles).

### The shim (validated verbatim against Postgres 17)

```sql
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
```

Rejected: **RLS applied out-of-band on Supabase only** (dual source of truth, contradicts
ADR-0006; test-DB never exercises RLS). Rejected: **per-environment SQL forks** (two texts of
record). Rejected: **`CREATE OR REPLACE FUNCTION auth.uid()` unconditionally** (clobbers
Supabase's real function and its GoTrue-aware behaviour).

## Verification (empirical, Postgres 17.9, 2026-07-03)

A probe reproduced the failure and proved the fix end-to-end against a real Postgres:

- **Break reproduced:** the raw RLS policy DDL fails on a clean DB with `schema "auth" does not
  exist` / `role "authenticated" does not exist`.
- **Shim fixes apply:** after the shim, the same `CREATE POLICY … TO authenticated USING
  ((SELECT auth.uid()) = id)` succeeds.
- **RLS actually filters:** inside a transaction with `SET LOCAL ROLE authenticated` and
  `request.jwt.claims = {"sub":"…1111"}`, `auth.uid()` returns `…1111` and a two-row table
  returns exactly the one owned row. This is the mechanism the test suite will use to assert
  policy behaviour.
- **Probe bug caught by the live DB, not by review:** the first shim omitted
  `GRANT USAGE ON SCHEMA auth` / `GRANT EXECUTE`, so `authenticated` still got
  `permission denied for schema auth`. Fixed and re-verified. (Kept here as evidence the
  validation is real.)

## Consequences

- A new no-model app (`platform_db`) holds the shim + extensions + trigger/function/view + RLS
  RunSQL migrations. It must be added to `INSTALLED_APPS`.
- The shim depends only on cluster state (roles/schema), so it carries **no** dependency on any
  model migration; the RLS migration depends on the shim **and** on the model apps' initial
  migrations.
- Every `reverse_sql` for the shim must be a safe no-op-ish teardown (e.g. `DROP FUNCTION IF
  EXISTS auth.uid();` guarded so it never drops Supabase's real one — in practice the shim is
  `RunSQL(sql, reverse_sql=migrations.RunSQL.noop)` because we never want a downward migration to
  remove auth objects on Supabase).
- **Contract with ADR-0001 restated:** RLS correctness depends on the JWT `sub` claim equalling
  `users.id`. ADR-0001 already commits us to this; ADR-0007 makes the test-DB able to prove it.
- CI's plain Postgres now applies the full RLS/GRANT layer, so the isolation tests run on every
  PR instead of only against a live Supabase.

## Addendum (2026-07-17): two findings from applying the layer end-to-end

Implementing this ADR as `platform_db` migrations 0001–0005 and running the full
`migrate` + behavioural probe against a fresh PostGIS+pgvector Postgres 17 surfaced two
gaps invisible to review:

1. **The shim needs a privilege baseline, not just roles + `auth.uid()`.** On Supabase,
   `anon`/`authenticated`/`service_role` hold blanket grants on the `public` schema — that
   baseline is what the canonical REVOKE block *subtracts from*. On plain Postgres the
   shim-created roles had no table privileges at all, so every client-role query died on
   table-level permission before any RLS policy was evaluated (the probe's
   `SELECT … FROM users` as `authenticated` failed with `permission denied`, not with an
   empty result). Fix: migration `0004_baseline_grants` emulates Supabase's baseline
   (`GRANT ALL ON ALL TABLES/SEQUENCES/FUNCTIONS` + `ALTER DEFAULT PRIVILEGES` for the
   three roles), sequenced **after** the model tables and **before** the RLS/REVOKE
   migration. Idempotent and harmless on Supabase.

2. **`security_invoker` + base-table REVOKE is a contradiction — the canonical spec had a
   real bug.** `v_appointments_safe` was specified `security_invoker = true` while the
   same spec REVOKEs the caller's SELECT on `appointments`: an invoker view executes with
   the caller's privileges, so the view was unreadable by exactly the clients it exists
   for — on Supabase and plain Postgres alike (threat-model I-4b endorses both halves of
   the contradiction). Fix (applied to `plans/veridian_schema.sql`, the text of record):
   the view is now **definer-style** with the patient/doctor ownership predicates
   **embedded in its WHERE clause** (mirroring the two appointments read policies), plus
   `security_barrier = true` against predicate-pushdown leaks, plus
   `REVOKE ALL … FROM anon` (anon structurally sees zero rows anyway, since
   `auth.uid()` is NULL). Verified: patient sees only their own appointment with the
   telehealth URL NULLed outside the 15-minute window; the doctor sees only their
   profile's appointments; anon is denied outright.
   **Follow-up (owner-visible):** threat-model I-4b, ADR-0001's RLS-hardening item 4, and
   any api-contract prose that says "security_invoker" still describe the old design and
   need reconciling to "definer-style view with embedded ownership predicates".
   *Reconciled 2026-07-18:* ADR-0001 item 4 corrected (with a dated note), threat-model
   I-4b's view control and Appendix A's inventory row now describe the definer-style
   mechanism. The api-contract needed no change — its two mentions of the view are purely
   behavioural (URL gating, "never the raw table") and were already accurate.

Everything above was verified live on 2026-07-17: full `migrate` from zero, the RLS
filter/REVOKE/hash-chain/`updated_at` probes, definer-view scoping for patient, doctor,
and anon, and Django's test-database creation (pytest) applying the entire layer.

## Open questions for the owner

1. Confirm the **no-model `platform_db` app** as the home for these RunSQL migrations (vs.
   scattering them into each vertical's `migrations/`). Recommended: one app, so the ordering and
   the shim-before-RLS dependency are in one place.
2. `service_role` is created `BYPASSRLS` here to match the prod write path. Confirm Django's
   prod DB role is (or maps to) `service_role`; if Django connects as a superuser/owner instead,
   `BYPASSRLS` is moot but harmless.

# ADR-0006 — Schema ownership: Django migrations are canonical; DDL delivered via RunSQL

- **Status:** Accepted (2026-07-01). Decisions: (1) **Django-migrations-canonical** — models
  `managed=True`; RLS/triggers/functions/views/GRANT via `RunSQL` from versioned `.sql` files.
  (2) **Enums = `TextChoices` + `CHECK` constraints, NOT native Postgres enums** (rationale
  below — reversed from the initial lean). (3) **`users.password`** nullable, added to the
  canonical schema. Models built per this ADR; migrations + RunSQL generated in a Postgres/
  Django env (CI or local 3.13 + Postgres), which is the verification gate.
- **Date:** 2026-07-01
- **Deciders:** Lead engineer + project owner
- **Related:** `plans/veridian_schema.sql`, BUILD_PROMPT §3.9 (append-only migrations,
  "never raw SQL in production"), implementation-plan Phase 0, `apps/api/identity/models.py`

## Context

Two artifacts both claim to define the database:

1. `veridian_schema.sql` — a hand-written, canonical DDL with 32 tables **plus** RLS policies,
   triggers, functions, the audit hash-chain, `v_appointments_safe`, and GRANT/REVOKE.
2. BUILD_PROMPT's rule: **"always Django migrations; never raw SQL in production; never edit an
   applied migration"** and CI runs `makemigrations --check --dry-run` (drift = blocker).

These pull in opposite directions. If the `.sql` is run out-of-band against Supabase and Django
models are `managed=False`, Django's own tooling fights it (migrations, test-DB creation) and
the "always Django migrations" rule is violated. If Django migrations own everything, then the
RLS/triggers/functions/hash-chain — which Django cannot express as model operations — have no
home.

A concrete instance already bit us: Django's `AbstractBaseUser` requires a `password` column,
but the canonical `users` table has none (auth is OTP/JWT). So the model and the DDL do not
match as written.

## Decision (recommended)

**Django migrations are the mechanism and the history; the canonical DDL content is delivered
*through* migrations.**

- Tables, columns, indexes, and constraints are created by normal Django model operations
  (`managed = True`), so `makemigrations --check` stays green and test databases build.
- RLS policies, triggers, functions, the audit hash-chain, `v_appointments_safe`, and
  GRANT/REVOKE are applied via `migrations.RunSQL` operations whose SQL is kept in versioned
  files under `apps/api/*/migrations/sql/` — sourced verbatim from `veridian_schema.sql` so
  there is **one text of record** for that layer.
- `veridian_schema.sql` is retained as the **authoritative design spec** the initial migration
  must reproduce; a CI parity check diffs the migrated DB against it.
- This satisfies both "always Django migrations" (nothing runs out-of-band) and "the database
  is the contract" (RLS/triggers ship, versioned and append-only).

Rejected: **SQL-canonical + `managed=False`**. It breaks Django migrations/tests, contradicts
BUILD_PROMPT, and offers no way to keep the ORM honest.

### The `users.password` reconciliation

Add a nullable `password` column to the canonical `users` table (Django-managed), unused for
OTP users (`set_unusable_password()`), usable only for `platform_admin` bootstrap. Update
`veridian_schema.sql` + `veridian-database-schema.md` so the DDL matches the Django-managed
`users` (which is the superset: adds `password`, keeps `last_login_at`). Alternatively, drop
`password` and store the admin bootstrap secret elsewhere — but a nullable column is simplest
and standard.

## Consequences

- The 32 models are written `managed=True`, mapping 1:1 to the schema (`db_table`, exact field
  types: UUID, JSONB→`JSONField`, `ArrayField`, `pgvector` via `django-pgvector`, PostGIS via
  `django.contrib.gis`). Enum types: use Postgres enums via a migration, or `TextChoices` +
  `CHECK` — decide per column (open question 2).
- Initial migration(s) carry the RLS/trigger/function/view/GRANT SQL as `RunSQL` with matching
  `reverse_sql`. Append-only thereafter.
- CI adds a schema-parity job once models land (the Postgres service the ci.yml note refers to).
- `veridian_schema.sql` and `veridian-database-schema.md` get the `users.password` update.

## Open questions for the owner

1. Confirm **Django-migrations-canonical** (recommended) over SQL-canonical/`managed=False`.
2. ~~Postgres enums vs `TextChoices`+CHECK~~ **DECIDED: `TextChoices` + `CHECK`.** On
   reflection this beats native PG enums *because* of our own append-only-migration mandate:
   altering a Postgres enum is a known trap — you cannot remove a value, and adding one has
   transaction restrictions — so a schema that must evolve under "never edit an applied
   migration" is far safer with `varchar + CHECK` (a CHECK is trivially replaced by a new
   migration). RLS/queries compare enum values as strings either way (`status = 'available'`),
   so there is no functional loss. The canonical `.sql` keeps native enums as *design
   documentation*; the Django-managed runtime uses `varchar + CHECK`.
3. **DECIDED: keep a nullable `users.password`** (added to `veridian_schema.sql`). Unused for
   OTP users; set only for `platform_admin` bootstrap.

# Veridian

All-in-one service booking platform — Phase 1 vertical: doctor booking. Ghana-first.

Authoritative design lives in [`plans/`](plans/) and decisions in [`docs/adr/`](docs/adr/).
Read [`BUILD_PROMPT.md`](BUILD_PROMPT.md) before contributing.

## Monorepo layout

```
apps/
  api/        # Django REST API (backend) — the source of truth for business logic
  web/        # Next.js 14 web app         (scaffold pending)
  mobile/     # Flutter app                (scaffold pending)
packages/
  shared-types/   # OpenAPI-generated TS types  (pending)
  design-tokens/  # colour/spacing tokens        (pending)
infra/
  github-actions/ # reusable CI bits             (pending)
docs/adr/     # Architecture Decision Records (0001–0005 accepted)
plans/        # authoritative design documents
scripts/      # tooling, CI gate scripts       (pending)
```

## Launch scope (ADR-0005)

v1.0 is **online-first, in-person only**: auth, doctor KYC, profiles/slots, SQL search, the
atomic booking transaction (Paystack + pay-at-desk), appointment state machine, encrypted
health timeline + consent, notifications, payouts + WHT. Telehealth → v1.1, offline write
engine → v1.2, semantic search → v1.3. All security/compliance controls ship in v1.0.

## Backend quickstart (`apps/api`)

```bash
cd apps/api
python -m venv .venv && source .venv/bin/activate
pip install -e '.[dev]'
cp ../../.env.example ../../.env   # then fill in real values (never commit .env)
python manage.py check
DJANGO_SETTINGS_MODULE=config.settings.test pytest
```

## Phase 0 status

- [x] Monorepo skeleton + `.gitignore`
- [x] Django project: settings split (base/dev/staging/prod/test), env structure
- [x] `TimestampedModel`, `SoftDeleteModel` base classes
- [x] Custom user model (`identity.User`) — before first migration
- [x] Health endpoint `/api/v1/health` + error envelope + CI skeleton
- [ ] **ADR-0006 (next): schema ownership** — SQL file vs Django migrations (see below)
- [ ] Django models for all 32 tables (blocked on ADR-0006)
- [ ] Apply schema to a Supabase project + JWKS third-party auth (ADR-0001)
- [ ] Flutter + Next.js scaffolds, Railway deploy

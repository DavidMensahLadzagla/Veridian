# ADR-0002 — Idempotency for replayable mutations (offline queue + webhooks)

- **Status:** Accepted (2026-07-01). `idempotency_keys` table added to `veridian_schema.sql`; `X-Idempotency-Key` documented in `veridian-api-contract.md` and added to `veridian_openapi.yaml`.
- **Date:** 2026-07-01
- **Deciders:** Lead engineer + project owner
- **Related:** `plans/veridian-offline-sync.md` (queue), `plans/veridian_openapi.yaml`,
  `plans/veridian-state-machines.md` (payment webhook idempotency), threat-model T-1/T-3

## Context

The Flutter offline queue sends an `X-Idempotency-Key` header on replayable mutations
(`offline-sync.md:158,277,283`). But:
- The header **does not appear in the OpenAPI spec** — it is not part of the frozen wire
  contract.
- There is **no server-side idempotency store** in the schema.

Consequence: a booking whose HTTP response is lost on a flaky connection (the *expected* case
in Ghana, and the whole reason offline-first exists) gets retried with the same key. Without a
dedup store, the retry runs the booking transaction **again** → a second slot reservation,
possibly a second Paystack init, a duplicate appointment. This is precisely the trust-breaking
double-booking that threat-model T-1 exists to prevent, arriving through the front door.

Payment webhooks already specify idempotency-by-status (`state-machines.md:995`), but that is a
different mechanism (status check on a known row) and does not cover client-initiated retries
of *creating* new resources.

## Decision drivers

1. At-least-once delivery from the offline client must produce at-most-once server effect.
2. Must cover the operations the queue can replay: `createAppointment`, `cancelAppointment`,
   `rescheduleAppointment`, and any other non-GET mutation the queue dispatches.
3. Must be safe under concurrency (the same key arriving twice near-simultaneously).
4. Keep it boring and auditable.

## Decision

### 1. First-class header in the contract

Add `X-Idempotency-Key: <uuid>` to the OpenAPI spec as an **optional-but-honoured** request
header on every mutating endpoint the offline queue can replay (required from the mobile
client; server treats absence as "no dedup"). Document the response semantics: a replay
returns the **original** response (status + body), not a fresh execution.

### 2. Server-side idempotency store

New table (add to schema as a migration; this is Django-only, `service_role`-written, RLS
denies all client access):

```sql
CREATE TABLE idempotency_keys (
    key             UUID NOT NULL,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    endpoint        VARCHAR(100) NOT NULL,          -- method + path template
    request_hash    VARCHAR(64)  NOT NULL,          -- SHA-256 of canonical request body
    status          VARCHAR(20)  NOT NULL DEFAULT 'in_progress',  -- in_progress|completed
    response_code   SMALLINT,
    response_body   JSONB,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    PRIMARY KEY (key, user_id)
);
CREATE INDEX idx_idem_gc ON idempotency_keys(created_at);
```

### 3. Middleware / decorator flow

On a mutating request carrying `X-Idempotency-Key`:
1. `INSERT ... ON CONFLICT (key, user_id) DO NOTHING` with `status='in_progress'`.
   - **Insert won:** this is the first execution. Proceed; on completion, `UPDATE` the row
     with `status='completed'`, `response_code`, `response_body`.
   - **Conflict (row exists):**
     - `status='completed'` → return the stored `response_code`/`response_body` verbatim.
     - `status='in_progress'` → the original is still running (a fast double-fire); return
       `409 IDEMPOTENCY_IN_PROGRESS` with `Retry-After`. Client retries later and gets the
       stored result.
2. **`request_hash` guard:** if the same key arrives with a *different* body hash, return
   `422 IDEMPOTENCY_KEY_REUSED`. A key is bound to one request payload.
3. Scope the key to `user_id` so keys can never collide or leak across users.

The idempotency `INSERT` is committed independently of the business transaction so that a
crash mid-booking still leaves a claimable key (the row can be reclaimed if `in_progress` and
older than a timeout, or simply retried since the business txn rolled back). Keep the window
tight and covered by tests.

### 4. Retention

A daily GC deletes `completed` keys older than 7 days (well beyond the offline queue's
`critical` 10-minute / `standard` 24-hour staleness thresholds in `offline-sync.md`).

## Consequences

- `veridian_openapi.yaml` gains the header on ~6 endpoints; the API contract doc gets a short
  "Idempotency" section.
- The booking service (`POST /appointments`) is the highest-value consumer and must have an
  explicit test: *same idempotency key twice → one appointment, one reservation, one payment
  intent, identical response both times.* Add to the Phase 4 gate alongside the concurrent-
  booking test.
- Webhooks keep their existing status-check idempotency; this ADR is about **client** retries.

## Open questions for the owner

1. None blocking. Confirm 7-day key retention is acceptable (it exceeds all queue staleness
   windows, so replays always resolve against a stored result rather than re-executing).

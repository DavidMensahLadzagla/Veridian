# ADR-0003 — What clients may read directly from Supabase (and what must go through Django)

- **Status:** Accepted (2026-07-01). Owner approved: drop `health_timeline_entries` + `bank_accounts` from direct-read (Django-only); keep `v_appointments_safe` in Tier 2 (Realtime on appointments). Threat-model Appendix A and api-contract corrected accordingly.
- **Date:** 2026-07-01
- **Deciders:** Lead engineer + project owner
- **Related:** `plans/veridian-threat-model.md` Appendix A, `plans/veridian-api-contract.md`
  §"Supabase Direct Access", `plans/veridian-offline-sync.md`, ADR-0001

## Context

The plans **disagree with themselves** about direct Supabase reads:

- `api-contract.md:92` says clients read only **public** data directly (available slots via
  Realtime, doctor embedding search) — everything else via Django.
- `threat-model.md` Appendix A lists **authenticated** direct-reads including
  `health_timeline_entries`, `v_appointments_safe`, `consent_grants`, `saved_doctors`,
  `notification_preferences`, `bank_accounts`.

These cannot both be the contract. And one item is not just a contradiction but a **design
error**:

**`health_timeline_entries` cannot usefully be direct-read.** Its `content_encrypted` is
AES-256-GCM ciphertext under a **per-patient key derived in Django memory via HKDF** from a
master key that only Django holds (impl-plan §Data Protection; schema `patient_key_salt`). A
Supabase direct read returns bytes the client **cannot decrypt**. Reading it directly buys
nothing and widens the RLS attack surface over PHI for zero benefit.

`bank_accounts` is analogous: account numbers are app-level encrypted and the API is meant to
return only last-4 (universal standards, `veridian-prompt_.md`). Direct-reading the row
exposes ciphertext + metadata for no product gain.

## Decision drivers

1. Direct reads exist for **latency and Realtime**, not as a general data path.
2. Every table exposed to direct read makes **RLS the sole authorization layer** — each one is
   a standing BOLA risk that must be independently tested (threat-model I-1).
3. Encrypted-at-rest PHI gains nothing from direct read (client can't decrypt).
4. Consistency: the two documents must be reconciled to one authoritative list.

## Decision

Adopt a **tiered, minimal** direct-read policy. `threat-model.md` Appendix A becomes the single
source of truth; `api-contract.md` is corrected to point at it.

### Tier 1 — Direct read, anon + authenticated (public discovery)
`slots`, `doctor_profiles` (minus the `profile_embedding` column), `doctor_specializations`,
`doctor_languages`, `clinic_affiliations`, `clinics`, `reviews`.
→ Public data; Realtime on `slots` is the core UX. Keep.

### Tier 2 — Direct read, authenticated, **non-PHI** (owner-scoped convenience/Realtime)
`v_appointments_safe` (URL-gated view; **never** the raw `appointments` table),
`consent_grants`, `saved_doctors`, `notification_preferences`.
→ These are small, owner-scoped, benefit from Realtime/offline, and carry no encrypted-blob
problem. Keep, **conditional on ADR-0001** (the auth bridge must make `auth.uid()` real) and on
each having the hardened RLS from ADR-0001 (`TO authenticated` + ownership `USING` **and**
`WITH CHECK`).

### Tier 3 — **Remove from direct-read; Django-only**
`health_timeline_entries` (encrypted; client can't decrypt — must hit Django to get
decrypted content and consent-checked doctor reads), `bank_accounts` (encrypted financial;
last-4 only via API).
→ Delete these two rows from Appendix A. Timeline content is served by a DRF endpoint that
decrypts in memory and enforces consent (Django + RLS both still apply on the service-role
path).

### Everything else — Django-only (unchanged)
`appointments` (raw), `payment_transactions`, `payouts`, `audit_log`,
`refresh_token_blocklist`, `idempotency_keys`, `users`.

### Keep the CI gate, point it at the corrected list
`scripts/check_direct_read_inventory.py` greps `supabase.from('<table>')` in the Flutter/web
clients and fails if a table is not in Tier 1/2. Update it to also fail on **Tier 3** tables
explicitly (so a future dev can't "optimize" timeline reads by going direct).

## Consequences

- Appendix A shrinks by two rows; api-contract §"Supabase Direct Access" is rewritten to
  reference Appendix A as authoritative and to state "authenticated direct reads are limited to
  Tier 1–2; PHI and financial rows are Django-only."
- The direct-read RLS test suite drops the `health_timeline_entries` direct cases (moves them to
  DRF endpoint tests) and keeps `v_appointments_safe`, `consent_grants`, `saved_doctors`.
- Lower PHI blast radius if the ADR-0001 auth bridge ever has a bug: no encrypted PHI is
  reachable by the direct path at all.

## Follow-up flagged during fold-in (needs verification before Phase 4)

Revoking base-table `SELECT ON appointments FROM authenticated` (threat-model I-4b, applied
in the schema) collides with a Supabase reality: **Realtime "Postgres Changes" is table-level,
not view-level**, and delivery is gated on the subscriber passing SELECT on the *base table*.
So a client cannot get Realtime on `appointments` while also being denied base-table SELECT —
and it cannot subscribe to the `v_appointments_safe` *view* at all (Realtime doesn't watch
views). `offline-sync.md` currently subscribes directly to `appointments` (its
`_setupRealtimeSubscriptions`), which will not work under this revoke.

**Recommended resolution (safe default):** appointment status changes ride on **push
notifications + the existing 60s pull-sync** (both already specified in offline-sync.md); keep
Supabase Realtime only on `slots`, which is fully public and unambiguous. Realtime "live"
appointment updates become a nice-to-have handled by push, not a hard dependency on exposing
the appointments table. Verify current Supabase Realtime authorization behaviour before
committing, and update `offline-sync.md` §Realtime Subscriptions accordingly. Tracked so the
`TestRealtimeRLS` case and the sync engine are built against the resolved model.

## Open questions for the owner

1. **Confirm removing `health_timeline_entries` and `bank_accounts` from direct-read.** I
   strongly recommend it (they can't be decrypted client-side anyway). The only cost is that the
   patient's *own* timeline list refreshes via a Django call rather than Supabase Realtime —
   acceptable, since timeline entries are not real-time-critical (offline-sync sets timeline
   max-staleness at 5 min).
2. **Do you want Realtime on appointments for patients?** If yes, `v_appointments_safe` stays in
   Tier 2 (recommended). If you'd rather keep all appointment reads in Django for uniformity, we
   drop Tier 2 to just `consent_grants`/`saved_doctors`/`notification_preferences` and lean on
   push notifications for status changes.

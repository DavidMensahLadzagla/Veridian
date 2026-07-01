# ADR-0005 — Launch scope: online-first, prove-the-loop-safely, compliance in parallel

- **Status:** Accepted (2026-07-01). Owner decisions: (1) telehealth → **v1.1** (not launch);
  (2) mobile v1.0 = **read-through cache only** (offline writes → v1.2); (3) v1.0 coverage =
  **strict on the loop (100% critical-path), ~80% elsewhere**. Folded into implementation-plan
  Part 7, veridian-prompt Section 6, and BUILD_PROMPT Phase-1 gate.
- **Date:** 2026-07-01
- **Deciders:** Project owner (final call) + lead engineer
- **Related:** `plans/veridian-implementation-plan.md` (Part 7 roadmap),
  `veridian-prompt_.md` (Phase 0–10), `BUILD_PROMPT.md` (Phase gates),
  `plans/veridian-offline-sync.md`, ADR-0002 (idempotency)

## Context

The plans are excellent, but they bundle a multi-quarter program into a "Phase 1 / 14 weeks"
that, as written, ships simultaneously: Django API + a **local-first Flutter app with a full
offline sync engine (10 conflict scenarios)** + Next.js SSR web + full RLS + Celery + Paystack
+ **telehealth** + **semantic search** + WORM audit chain + WebAuthn admin + a multi-vertical
abstraction — all under strict TDD with 90/85/80% coverage, goldens, Playwright, patrol, axe,
load and chaos drills, a pen test, and a DPIA.

Any one of the bolded items is a project in itself. The offline sync engine especially is the
most under-estimated line in the whole plan: a correct local-first app is a *product*, not a
feature. Shipping all of this at once maximises the chance of shipping **nothing** on time.

Two more realities shape this decision:

1. **Compliance is the true critical path, not code.** DPC registration, a named DPO, signed
   DPAs with 8 sub-processors, legal review of 7 documents, Paystack KYB, a DPIA, and an
   external pen test all have long *external* lead times (weeks–months) that engineering cannot
   compress. If these don't start on day one, they — not the code — set the launch date.
2. **We just made idempotency a prerequisite (ADR-0002).** Server-side idempotency is the
   foundation the offline write-queue sits on. The correct sequence is therefore: build the
   online booking loop *with* idempotency, prove it in production, *then* layer the offline
   queue on top — not the reverse.

## Decision drivers

1. Ship a **viable, safe** product on a sane timeline; iterate from real usage.
2. Cuts come from **product surface**, never from the safety controls that make a health
   platform defensible. "Online-first" is not "insecure-first."
3. Sequence deferred work so each stage de-risks the next (idempotency → offline; online loop →
   telehealth realtime).
4. Preserve the differentiators as a credible *roadmap*, not a launch bet-the-company scope.

## Decision

Launch **v1.0 = "the core loop, online, safe"** on both web and mobile, with the mobile app
**online-first** (no offline write engine at launch). Defer the high-cost differentiators to
prioritised fast-follows. Run the compliance track in parallel from day one.

### In scope for v1.0 (the loop that proves the business)

- Identity & auth: OTP (Termii), the Django⇄Supabase JWT bridge (ADR-0001), refresh rotation,
  **WebAuthn for platform_admin** (non-negotiable, threat-model E-5).
- Doctor KYC + manual GMDC verification; the KYC state machine.
- Doctor profiles, availability templates, slot generation (with the ADR-0004 tz model).
- **SQL search + filters** (specialization, location/PostGIS, language, mode, date, price).
- **The booking transaction** — the crown jewel: atomic, `SELECT FOR UPDATE`, race-safe,
  **idempotent (ADR-0002)**, Paystack + pay-at-desk. Full appointment state machine (T1–T12).
- Health timeline (Django-mediated, encrypted, `key_version`) + consent grants.
- Notifications (push/SMS/email via Celery), appointment management, reschedule/cancel/refund.
- Payouts + 15% WHT remittance.
- **In-person consultations only** at launch (see open question 1 on telehealth).

### Non-cuttable — ships in v1.0 regardless (this is the "safely")

Hardened RLS (ADR-0001), per-patient encryption, the append-only audit hash-chain + WORM
archive, BOLA/mass-assignment/webhook-HMAC controls, rate limiting, the direct-read CI gate,
`DEBUG=False` + error envelope, secrets in a vault, the pen test, and the DPIA. **None of the
security or compliance controls are in the cut set.** The cut set is product surface only.

### Deferred to fast-follow (prioritised, post-launch)

| Order | Item | Why deferred / why this order |
| ----- | ---- | ----------------------------- |
| v1.1 | **Telehealth** (Daily.co, URL-gate already designed) | Adds real-time infra + clinical/legal disclaimers; layer once the booking+payment+records loop is bulletproof. Strong wedge — first fast-follow. |
| v1.2 | **Offline sync engine** (queue + 10 conflict scenarios) | Largest/riskiest build; sits on ADR-0002 idempotency, which must be proven online first. See staged approach below. |
| v1.3 | **Semantic search** (OpenAI embeddings, pgvector) | Already behind `semantic_search_enabled` flag; SQL search is sufficient to launch. Cost/PII-audit machinery can mature post-launch. |
| v1.x | Stripe/international, family accounts, AI appointment brief | Not on the core loop. |
| v2+ | **Multi-vertical** (barber/mechanic) | Not in the schema today (no `service_providers` table). A real refactor when a second vertical is greenlit — not a free "add an app." |

### Offline-first, staged (handling the one contentious cut)

Offline-first is billed as a Ghana-connectivity differentiator, so cut it *deliberately*, not
silently, and in two stages:

- **v1.0 — read-through cache only.** The Flutter app reads local (Drift) first and refreshes
  in the background, so browsing saved doctors and viewing appointments works on a poor
  connection. **No write queue, no conflict resolver, no offline booking.** This keeps most of
  the perceived-speed benefit at a fraction of the cost and risk.
- **v1.2 — full offline writes.** The operation queue, `X-Idempotency-Key` replay, and the 10
  conflict scenarios, added once the online booking API (with idempotency) is proven in
  production. The hard part is offline *writes*, not offline *reads* — this split banks the
  cheap value now and buys down the expensive risk later.

### Compliance track — starts day one, runs in parallel (not gated by code)

Owner/Legal own this from week 1: incorporate the GH entity, DPC registration + DPO, sign the
8 sub-processor DPAs, draft + lawyer-review the 7 legal documents, Paystack KYB, provision the
WORM audit bucket. Engineering supports (consent flows, retention task, export/delete
endpoints) but the external filings are the pacing item. **No production PHI is collected until
the Phase-0 non-code gates in BUILD_PROMPT are green.**

## Consequences

- The `veridian-prompt_.md` phase order stays valid for **v1.0** through Phase 7 (Payments),
  with two changes: **Phase 6-telehealth and Phase 10-semantic-search move out of the launch
  set**, and **Phase 8-mobile ships online-first** (offline engine becomes its own later phase).
- Definition of **launch-ready** (tighter than the current Phase-1 gate): the core loop passes
  its critical-path tests (concurrent-booking, idempotent-replay, every state transition,
  consent-bypass, encryption, webhook-idempotency, payout WHT), the pen test's P0/P1 are fixed,
  the DPIA is signed, and the Phase-0 compliance gates are green. Coverage targets apply to the
  **shipped** surface; deferred modules carry their targets when they ship.
- Roadmap docs to update on acceptance: implementation-plan Part 7, the phase list in
  veridian-prompt_.md, and the BUILD_PROMPT phase gates — to reflect the cut-line and the
  parallel compliance track.

## Open questions for the owner

1. **Telehealth in v1.0, or v1.1?** I recommend **v1.1** (get the money+records loop
   bulletproof first). But if reaching underserved areas by video is the *primary* wedge for
   your first users, it moves into v1.0 — that's a business call, not an engineering one.
2. **Offline in v1.0: read-through cache only (recommended), or none at all?** Read-only cache
   is modest effort and preserves the connectivity story; "none" is simplest but makes the
   mobile app feel ordinary on a bad connection.
3. **Coverage tax at launch:** hold the full 90/85/80 + goldens + patrol + axe on the v1.0
   surface (safer, slower), or a pragmatic "100% on the critical-path modules, 80% elsewhere"
   for launch and raise the bar as it stabilises? I lean pragmatic-but-strict-on-the-loop.

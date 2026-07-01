# ADR-0004 — Slot time is stored as an absolute instant, not naive wall-clock

- **Status:** Accepted (2026-07-01). Q1: timezone is **per `clinic`**. Q2: telehealth-only
  (clinic-less) slots fall back to the **doctor's `users.timezone`**. Folded into
  `veridian_schema.sql` (`clinics.timezone`, `slots.start_at`/`end_at`, view gate) and
  `veridian-state-machines.md` (T3/T10/T11 guards + service example).
- **Date:** 2026-07-01
- **Deciders:** Lead engineer + project owner
- **Related:** `plans/veridian_schema.sql` (`slots`, `v_appointments_safe`),
  `plans/veridian-state-machines.md` (T3 start guard, reminder ETAs), threat-model I-4b

## Context

`slots` stores `slot_date DATE` + `start_time TIME` + `end_time TIME` — **naive local
wall-clock with no timezone attached.** Multiple consumers then reconstruct an instant from
those fields to make time comparisons:

- The telehealth gate in `v_appointments_safe`:
  `s.slot_date + s.start_time <= NOW() + INTERVAL '15 minutes'`.
  `slot_date + start_time` is `timestamp` (no tz); `NOW()` is `timestamptz`. Postgres coerces
  the naive value using the **session `TimeZone` GUC**. It is only correct today because Ghana
  is UTC+0 and the session runs in UTC. It is a security-sensitive gate (premature telehealth
  URL disclosure).
- The T3 start guard: `NOW() >= slot.start_time - 30 min` (Python service layer).
- Reminder scheduling: `schedule_reminder_24h` ETA = `slot_datetime - 24h`.
- Slot generation: builds slots from availability templates in local time.

Each of these independently turns "wall-clock date+time" into an instant. That is the exact
shape of bug we keep fixing: **the correctness is duplicated across the view, the DRF
serializer, Celery, and the service layer, so the four paths can — and eventually will —
disagree.** And the moment the platform serves a zone other than UTC+0 (the stated goal:
"across Africa" — Nigeria UTC+1, Kenya UTC+3), or the DB session TZ is ever not UTC, the naive
math is simply wrong.

`slots` has no timezone. `clinics` has no timezone. `users.timezone VARCHAR(60)` **does**
exist (default `Africa/Accra`).

## Decision drivers

1. Time comparisons must be **timezone- and DST-safe**, and correct for multi-country
   operation, not just Ghana.
2. The view gate and the DRF serializer must be **impossible to drift** — ideally they compare
   the same stored value with no per-path tz math.
3. Preserve the local wall-clock semantics doctors actually set ("I consult 09:00–17:00 local")
   and the `UNIQUE(doctor_profile_id, slot_date, start_time)` invariant.
4. Minimal, well-contained change (no code exists yet — this is a plan/schema decision).

## Options considered

### Option A — Add authoritative `start_at` / `end_at` `timestamptz` to `slots` — *recommended*

Keep `slot_date` / `start_time` / `end_time` as the **local wall-clock** representation (for
display, date filtering, and the uniqueness constraint). Add two **absolute-instant** columns:

```sql
ALTER TABLE slots
    ADD COLUMN start_at TIMESTAMPTZ,   -- absolute instant of slot start (authoritative for all time math)
    ADD COLUMN end_at   TIMESTAMPTZ;
-- After backfill, both are NOT NULL. CHECK (end_at > start_at).
```

The **slot generation task** computes these once, from the slot's governing IANA timezone:
- **In-person slots:** the clinic's timezone (new column — see below).
- **Telehealth-only slots** (nullable `clinic_affiliation_id`): fall back to the doctor's
  `users.timezone` (already in the schema).

```sql
ALTER TABLE clinics ADD COLUMN timezone VARCHAR(60) NOT NULL DEFAULT 'Africa/Accra';  -- IANA name
```

Generation resolves `tz = clinic.timezone` if a clinic affiliation exists, else the doctor's
`users.timezone`, and converts the wall-clock (`slot_date` @ `start_time` in `tz`) to a UTC
instant. Because the conversion uses the IANA zone **for that future date**, DST transitions
between generation and the slot date are handled correctly by the tz database (`zoneinfo`).

Every consumer then compares **instant to instant**, no tz math:
- View gate becomes: `WHEN s.start_at <= NOW() + INTERVAL '15 minutes' THEN url`.
- DRF serializer: `slot.start_at <= timezone.now() + timedelta(minutes=15)`. Both compare the
  same stored `timestamptz` — **they cannot drift.**
- T3 guard: `NOW() >= slot.start_at - 30 min`, `NOW() <= slot.start_at + duration + 60 min`.
- Reminder ETAs: `slot.start_at - 24h` / `- 1h`.

**Pros:** correctness computed once, at generation; every read path is a trivial instant
comparison; DST- and multi-country-safe; local semantics and uniqueness preserved.
**Cons:** two extra columns and a `clinics.timezone` column; generation must resolve the zone.

### Option B — Keep naive columns, convert at every query with `AT TIME ZONE`

Store `clinics.timezone`; write every comparison as
`(s.slot_date + s.start_time) AT TIME ZONE <tz> <= NOW() + …`.

**Pros:** no new instant columns. **Cons:** every consumer (view, serializer, Celery, service
layer) must remember to join the zone and apply `AT TIME ZONE` — reintroducing the duplicated,
drift-prone math this ADR exists to kill. Also unclear zone source for clinic-less telehealth
slots. Rejected: it fixes the symptom, not the shape of the bug.

### Option C — Store slot times in UTC only (drop local)

Rejected: loses the doctor's local wall-clock intent and makes DST corrupt recurring
availability.

## Decision (recommended)

Adopt **Option A**. `slots.start_at` / `end_at` (`timestamptz`) are the single source of truth
for all slot time math; `slot_date` / `start_time` / `end_time` remain the local wall-clock
representation for display, date filters, and uniqueness. Add `clinics.timezone` (IANA);
generation resolves the zone as clinic-tz, else doctor `users.timezone`.

## Consequences

Switch these to `start_at` / `end_at` (all become plain instant comparisons):
- `v_appointments_safe` telehealth gate (schema) and the symmetric DRF serializer gate.
- State machine T3 start-window guard; the `TOO_EARLY_TO_START` / `START_WINDOW_EXPIRED`
  checks in `appointments/services.py`.
- `schedule_reminder_24h` / `schedule_reminder_1h` ETAs, and reschedule (T12) reminder resets.
- No-show guard (`NOW() >= slot.start_at + duration`).
- Slot generation task: compute and write `start_at`/`end_at`; add tz resolution + a test that
  a Lagos clinic (UTC+1) and an Accra clinic (UTC+0) with the same local `start_time` produce
  `start_at` values one hour apart.
- `slots_public_read` RLS keeps using `slot_date >= CURRENT_DATE` (a local-date display filter);
  unchanged.
- Add a test asserting the view gate and the DRF serializer return identical
  visible/hidden results for a slot straddling the T-15 boundary (the anti-drift guarantee).

## Open questions for the owner

1. **Timezone granularity:** per-`clinic` (recommended — matches physical location) or
   per-`clinic_affiliation`? A doctor rarely spans zones within one clinic, so clinic-level is
   simplest; affiliation-level only matters if one clinic entity somehow operates across zones
   (not expected at launch).
2. Confirm the telehealth-slot fallback to the **doctor's** `users.timezone` is acceptable
   (the alternative is a platform default of `Africa/Accra`). Doctor-tz is more correct for a
   doctor consulting from another country.

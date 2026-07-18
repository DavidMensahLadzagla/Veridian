# Veridian — Master Implementation Plan

> An all-in-one service booking platform, starting with doctor booking built for dominance.

---

## Vision Statement

Veridian is not a feature-set — it is a **platform**. Every architectural decision below is made with two mandates in mind: (1) make the doctor booking experience so superior it embarrasses Practo and ZocDoc, and (2) ensure that adding barber booking or mechanic booking later requires zero structural surgery. You are not building a vertical; you are building a marketplace operating system.

---

## Part 1 — Product Philosophy & Differentiation Strategy

### What Practo and ZocDoc Get Wrong

Practo is bloated, slow, and confuses the patient journey. ZocDoc is geographically limited and clinic-centric. Both treat discovery and booking as the core loop — they do not treat the _patient relationship_ as the core asset.

### Veridian's Superiority

**Intelligent scheduling.** Not just "show available slots" — the platform learns doctor-specific behavior (a GP always runs 7 minutes late on Mondays, a specialist prefers afternoon bookings) and factors this into slot display, showing a "typical wait" indicator per provider, sourced from real anonymized historical data.

**Continuity of care thread.** Every patient has a health timeline — not a list of past bookings. Symptoms entered before one appointment are linked to diagnosis notes after. The next doctor a patient sees (even a different doctor) can optionally request access to this thread, with patient consent. No competitor does this in a meaningful way.

**Dynamic availability sync.** Clinics suffer from ghost slots — appointments that exist on paper but have been informally blocked by the doctor. Veridian tackles this with a real-time availability signal: doctors and their assistants can confirm or retract slots with a single tap, and the platform throttles patient-facing availability display to only show slots with a confidence score above a threshold.

**Contextual search, not just filters.** Patients can search "doctor near me who speaks Twi, sees children, open Saturday" and receive semantically ranked results, not just filter-and-list. This uses a lightweight embedding-based search over doctor profiles.

**Telehealth-first parity.** In-person and video consultations are not separate products — they are booking modes on the same slot. A doctor sets a slot as "either," and the patient chooses at booking time.

**Offline-first mobile.** In Ghana, connectivity is not guaranteed. A patient should be able to browse their saved doctors, view upcoming appointments, fill in a pre-consultation form, and queue a booking — all offline. When connectivity returns, the queue flushes automatically.

### Competitive Comparison

| Dimension     | Practo / ZocDoc             | Veridian                               |
| ------------- | --------------------------- | -------------------------------------- |
| Search        | Filter-and-list             | Semantic + proximity ranking           |
| Availability  | Doctor-managed, often stale | Dynamic, confidence-scored             |
| Continuity    | None                        | Health timeline with consent           |
| Offline       | None                        | Full offline-first on mobile           |
| Telehealth    | Separate product            | Integrated booking mode                |
| Post-visit    | Rating prompt               | Structured note + timeline entry       |
| Extensibility | Vertically siloed           | Multi-vertical platform                |
| Ghana-native  | No                          | Paystack, Termii, Twi language support |

---

## Part 2 — Technical Architecture

### 2.1 Monorepo Structure

```
Veridian/
├── apps/
│   ├── api/                    # Django REST API (core backend)
│   ├── web/                    # Next.js frontend
│   └── mobile/                 # Flutter app
├── packages/
│   ├── shared-types/           # OpenAPI-generated TS types (shared web ↔ mobile TS)
│   └── design-tokens/          # Color tokens, spacing (imported by web + referenced by mobile)
├── infra/
│   ├── docker/
│   ├── github-actions/
│   └── railway/
├── docs/
│   └── adr/                    # Architecture Decision Records
└── scripts/                    # DB migrations, seed scripts, tooling
```

### 2.2 Backend — Django Architecture

The Django project is organized as a set of bounded-context apps. Each app owns its models, serializers, views, and business logic. They communicate through well-defined service interfaces (Python functions), never by importing models across apps.

#### Django Apps

**`core`** — settings, base models (`TimestampedModel`, `SoftDeleteModel`), middleware, custom exception handlers, health check endpoint.

**`identity`** — User model (`AbstractUser` extension), roles (Patient, Doctor, Clinic Admin, Platform Admin), JWT issuance (SimpleJWT), OAuth 2.0 social auth (Google, Apple), device token registration.

**`doctors`** — Doctor profile, specializations, languages spoken, clinic affiliations, verification status (a doctor must be verified against GHS or relevant medical council before going live), availability templates, dynamic slot generation.

**`appointments`** — Booking, slot reservation with optimistic locking (prevents double-booking at the database level with `SELECT FOR UPDATE`), appointment status machine (`requested → confirmed → in-progress → completed | cancelled | no-show`), pre-consultation form submissions.

**`health_records`** — Patient health timeline, symptom logs, diagnosis notes (doctor-authored, patient-visible), file attachments (lab results, prescriptions — stored in Supabase Storage), consent grants.

**`notifications`** — Notification templates, delivery log, preference management. Celery tasks handle async delivery via FCM (push), Termii/Twilio (SMS), SendGrid/Resend (email).

**`payments`** — Paystack integration (primary, Ghana-native), Stripe (international), invoice generation, refund workflows, payout tracking for doctors on the platform.

**`search`** — Doctor search service, embedding generation (lightweight, pgvector in Supabase), contextual ranking.

**`admin_portal`** — Internal Django Admin customizations for platform operations.

#### Service Layer Pattern

No view should contain business logic. Every non-trivial operation goes through a service function:

```python
# appointments/services.py
def reserve_slot(patient_id, slot_id, mode) -> Appointment:
    with transaction.atomic():
        slot = Slot.objects.select_for_update().get(id=slot_id, status='available')
        if slot.status != 'available':
            raise SlotUnavailableError()
        slot.status = 'reserved'
        slot.save()
        appt = Appointment.objects.create(...)
        notify_doctor.delay(appt.id)
        return appt
```

#### Database Design Principles

Every table inherits from `TimestampedModel` (`created_at`, `updated_at`) and `SoftDeleteModel` (`deleted_at`, `is_deleted`). UUIDs as primary keys everywhere — no sequential integers exposed to clients. Money stored as integer cents to avoid floating point errors. All enum-like fields use Django `TextChoices`. Supabase Row Level Security (RLS) policies are the second enforcement layer — even if the API has a bug, the database refuses unauthorized reads.

#### Key Tables

| Table                     | Key Fields                                                                                                                                                        |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------- | ----------------------------------------------------------- |
| `users`                   | base identity, role flags, verification status, preferred language, timezone                                                                                      |
| `doctor_profiles`         | FK to user, specializations (array), languages (array), bio, `consultation_fee_pesewas`, rating_avg, rating_count, verification_status, license_number            |
| `clinic_affiliations`     | doctor_id, clinic_id, days_available (array), consulting_room                                                                                                     |
| `availability_templates`  | doctor_id, day_of_week, start_time, end_time, slot_duration_minutes, booking_mode (`in_person                                                                     | telehealth | either`), is_active |
| `slots`                   | generated from templates, date + start_time + end_time (local) + start_at/end_at (absolute instant, ADR-0004), status (`available                                                                                        | reserved   | booked              | blocked`), confidence_score (0.0–1.0), doctor_id, clinic_id |
| `appointments`            | slot_id, patient_id, doctor_id, status (state machine), booking_mode, pre_consultation_form (JSONB), patient_notes, estimated_wait_minutes, actual_start/end_time |
| `health_timeline_entries` | patient_id, linked_appointment_id (nullable), entry_type, content (JSONB), authored_by, visibility, attachments (array of storage keys)                           |
| `consent_grants`          | patient_id, granted_to_doctor_id, scope, granted_at, expires_at, revoked_at                                                                                       |

### 2.3 Supabase Configuration

Supabase provides PostgreSQL, Realtime, Storage, and the Auth layer for direct client access (Flutter reads/writes that bypass Django for performance).

**Realtime subscriptions** used for **slot availability updates only** (the `slots` table is public and in the direct-read inventory). Appointment status changes and in-app notifications propagate via **FCM push + pull-sync**, not Realtime — the raw `appointments` table SELECT is revoked from `authenticated` and Realtime is table-level, so it cannot watch the `v_appointments_safe` view (ADR-0003 / threat-model I-4b).

#### Row Level Security Examples

```sql
-- Patients can only read their own appointments
CREATE POLICY "patient_own_appointments"
ON appointments FOR SELECT
USING (auth.uid() = patient_id);

-- Doctors can read appointments assigned to them
CREATE POLICY "doctor_own_appointments"
ON appointments FOR SELECT
USING (auth.uid() = doctor_id);

-- Slots are publicly readable (for booking display)
CREATE POLICY "slots_public_read"
ON slots FOR SELECT
USING (status = 'available' AND date >= CURRENT_DATE);
```

#### Storage Buckets

- `profile-photos` — public
- `health-documents` — private, RLS-enforced, signed URL access only
- `prescription-pdfs` — private
- `clinic-photos` — public

### 2.4 Flutter Mobile Architecture

**State management:** Riverpod 2.x (providers, notifiers, async notifiers). Chosen over Bloc for its lower boilerplate and excellent async state handling with `AsyncValue`.

#### Offline-First Architecture

The core pattern is a local-first data model with a sync engine:

1. All reads go to the local database first (Drift/SQLite).
2. All writes go to a local operation queue (stored in a dedicated Drift table).
3. A background sync service, triggered by connectivity events, flushes the operation queue to the API and merges incoming server state into the local DB.
4. Conflict resolution uses a "server wins, but preserve local intent" strategy — if the server says a slot is gone, the user is notified and the queued booking is cancelled gracefully.

#### Key Packages

| Package                       | Purpose                                                                   |
| ----------------------------- | ------------------------------------------------------------------------- |
| `drift`                       | Type-safe SQLite ORM for local storage                                    |
| `riverpod`                    | State management                                                          |
| `dio`                         | HTTP client with interceptors for JWT refresh, retry, and request queuing |
| `connectivity_plus`           | Network state monitoring                                                  |
| `firebase_messaging`          | Push notifications (FCM)                                                  |
| `flutter_secure_storage`      | JWT and sensitive token storage                                           |
| `go_router`                   | Declarative routing with deep link support                                |
| `freezed`                     | Immutable model classes with `copyWith`, `toJson`, `fromJson`             |
| `flutter_local_notifications` | Local appointment reminders                                               |

#### Architecture Layers

**Data layer:** Drift tables + repository classes (one per domain). A repository has two data sources: `RemoteDataSource` (Dio-based API calls) and `LocalDataSource` (Drift queries). The repository decides which to use based on connectivity and cache staleness.

**Domain layer:** Pure Dart use cases. `BookAppointmentUseCase`, `SearchDoctorsUseCase`, `GetHealthTimelineUseCase`. These are framework-agnostic and fully unit-testable.

**Presentation layer:** Riverpod notifiers expose `AsyncValue<T>` states. Widgets consume these and render loading/error/data states.

#### Theme System

```dart
// Dark forest-green palette
class VeridianColors {
  static const forestGreen      = Color(0xFF0D3B2E);
  static const forestGreenLight = Color(0xFF1A5C46);
  static const accent           = Color(0xFF2ECC8F);
  static const accentMuted      = Color(0xFF1A9E6A);
  static const surface          = Color(0xFF0F2A22);
  static const surfaceElevated  = Color(0xFF163320);
  static const onSurface        = Color(0xFFE8F5F0);
  static const onSurfaceMuted   = Color(0xFFA3C4B8);
}

ThemeData lightTheme = ThemeData(
  colorScheme: ColorScheme.light(
    primary: Color(0xFF0D3B2E),
    secondary: Color(0xFF2ECC8F),
    surface: Color(0xFFF0FAF6),
  ),
);

ThemeData darkTheme = ThemeData(
  colorScheme: ColorScheme.dark(
    primary: Color(0xFF2ECC8F),
    surface: Color(0xFF0D3B2E),
  ),
);
```

Theme is persisted in `SharedPreferences` and controlled via a `ThemeNotifier` (Riverpod). System default is respected on first launch.

### 2.5 Next.js Web Architecture

**Stack:** Next.js (App Router), TypeScript, Tailwind CSS v4, shadcn/ui, TanStack Query v5.

**Web is light-theme only** with dark forest-green as the primary brand color on white/light surfaces. The green appears in headers, CTAs, highlights, navigation, and interactive elements.

#### Tailwind Color Tokens

```js
// tailwind.config.ts
theme: {
  extend: {
    colors: {
      forest: {
        50:  '#f0faf6',
        100: '#d4f0e5',
        200: '#a8e0ca',
        300: '#6dc4a6',
        400: '#35a37f',
        500: '#1a7a5e',
        600: '#0d5c47',
        700: '#0a4234',
        800: '#072e24',
        900: '#041e18',
      }
    }
  }
}
```

#### App Router Structure

```
app/
├── (marketing)/             # Public-facing pages (no auth required)
│   ├── page.tsx             # Landing
│   ├── doctors/
│   │   ├── page.tsx         # Doctor search/discovery
│   │   └── [slug]/page.tsx  # Doctor profile
│   └── how-it-works/
├── (patient)/               # Authenticated patient pages
│   ├── dashboard/
│   ├── appointments/
│   ├── health-records/
│   └── profile/
├── (doctor)/                # Authenticated doctor pages
│   ├── dashboard/
│   ├── schedule/
│   ├── patients/
│   └── earnings/
├── (clinic-admin)/          # Clinic management
└── auth/
    ├── login/
    └── signup/
```

#### Data Fetching Strategy

Server components fetch non-personalized data (doctor profiles, clinic info, specialization lists) at request time using the Django API with `fetch` — this gives SEO-crawlable HTML.

Client components use TanStack Query for personalized, interactive, and frequently updating data (appointment lists, slot availability, notifications). The `queryClient` is initialized on the server (via `HydrationBoundary`) and dehydrated into the HTML — the client gets pre-fetched data on first paint with no waterfall.

#### Authentication

NextAuth.js v5 handles session management. It is configured to use the Django JWT endpoint as a credentials provider, and Google/Apple as OAuth providers (Django receives these and issues its own JWTs). The session cookie is HTTP-only and secure. Middleware protects all authenticated route groups.

---

## Part 3 — Doctor Booking Feature Set (Phase 1 Deep Dive)

### 3.1 Patient Experience

#### Onboarding

Three screens: (1) Choose role (Patient / Doctor / Clinic). (2) Enter phone number, verify via OTP (Termii). (3) Set name, date of birth, and preferred language. No 12-field form.

#### Doctor Discovery

The search experience is the first impression — it must feel like Airbnb for doctors.

**Web:** Sticky search bar with inline filters (specialization, location, language, gender preference, booking mode, date). Results as a masonry-style card grid showing photo, name, specialization, languages, rating, consultation fee, and next available slot ("Today 3:30 PM" — never a raw date). Map view toggle shows clinics on an interactive map.

**Mobile:** Bottom sheet for filters, vertically scrolling card list. First 20 results load from local cache. Supabase Realtime keeps slot availability live.

#### Doctor Profile Page

Full photo header. Name, specializations, verification badge (GHS licensed). Languages, consultation modes, fee. Rating with breakdown (punctuality, communication, medical knowledge — each rated separately). Bio. Education and training. Clinic locations with map. Patient reviews with doctor reply capability. A "Save Doctor" button that persists locally offline.

The availability calendar is the core interaction: a week-strip at top lets patients navigate dates. Available slots appear as pill buttons. Slots with confidence score below 0.6 show a "⚠ May vary" label.

#### Booking Flow (5 Steps)

1. **Select slot** — date + time + mode (in-person or telehealth).
2. **Pre-consultation form** — reason for visit, symptoms duration, relevant medications, any uploaded documents. Form fields are doctor-configurable.
3. **Review and confirm** — fee, location/telehealth link, cancellation policy.
4. **Payment** — Paystack inline. Patient pays upfront, or clinic may allow pay-at-desk.
5. **Confirmation** — appointment card, calendar add button (generates `.ics`), sharing option.

All five steps run in a single animated wizard on mobile. On web, a two-column layout (sticky booking summary on right, form on left).

#### Appointment Management

Upcoming appointments card on the dashboard. Tap to view: doctor info, directions (Google Maps deeplink), telehealth link (visible 15 minutes before start time), pre-consultation summary, reschedule/cancel options (governed by doctor-set cancellation window).

Post-appointment: automated review prompt 2 hours after the scheduled end time. Review is structured (star ratings on 3 dimensions + optional text). Patients can also add a personal note to their health timeline immediately after.

#### Health Timeline

A chronological feed: past appointments (with diagnoses if doctor added notes), symptom logs (patient-authored), prescriptions, lab results. Filter by type or date. Entries can be marked as shareable with future doctors (consent-based). Exported as a PDF summary on demand (WeasyPrint).

#### Telehealth

Video calls use the Daily.co SDK — HIPAA-ready, Flutter-compatible, generous free tier. The call room is created by the server at booking confirmation. The room opens at appointment time and auto-closes after the scheduled slot duration + 10 minutes.

### 3.2 Doctor Experience

#### Doctor Onboarding (KYC Flow)

1. Basic info — name, specialization, languages.
2. Professional credentials — license number, issuing council (GHS, MDC, etc.), upload license scan.
3. Clinic affiliation — search and link to existing clinic, or create a new clinic profile.
4. Availability setup — visual weekly schedule builder. Doctor draws time blocks per day, sets slot duration (15 / 20 / 30 / 45 / 60 min), marks as in-person/telehealth/either.
5. Consultation fee — set per booking mode.
6. Platform review — admin verifies credentials before the profile goes live (typically 24–48 hours).

#### Doctor Dashboard

At-a-glance metrics: today's appointment count, this week's earnings, rating score, profile views. Day-view calendar shows today's appointments in chronological order. Each appointment card shows patient name, reason for visit, booking mode, and status. A "Start" button activates 5 minutes before appointment time.

#### During a Consultation

The appointment detail screen shows: patient's pre-consultation form, shared health timeline entries, past appointments with this doctor. Doctor adds a structured diagnosis note (diagnosis, ICD-10 code optional, recommendation, prescription, follow-up date). The note is encrypted at rest and the patient can view it immediately after the appointment is marked complete.

#### Availability Management

Doctors can block individual slots or entire days. They can temporarily deactivate their profile. The dashboard shows a "slot confidence" indicator — if the doctor has a history of blocking slots late, their confidence score drops and patients see the warning.

##### Slot Confidence Score — Formal Specification

Two related scores exist: `slots.confidence_score` (per-slot, seeded at `1.00`) and `doctor_profiles.slot_confidence_score` (per-doctor, rolling window). The formula below is authoritative — all jobs, tests, and UI thresholds must match it.

**Rolling window:** 60 days (configurable: `SLOT_CONFIDENCE_WINDOW_DAYS = 60`). A doctor with fewer than 10 scored events in the window is given a grace score of `1.00` and the "new doctor" label on the UI (no ⚠ warning shown).

**Per-event score.** For every slot in the window whose scheduled start has passed, compute an event score $e_i$:

| Event                                                                                                       | Event score $e_i$ |
| ----------------------------------------------------------------------------------------------------------- | ----------------- |
| Slot honoured (appointment `completed`, or `available`/`booked` and start passed without last-minute block) | 1.0               |
| Slot blocked ≥ 24 h before `slot.start`                                                                     | 0.9               |
| Slot blocked 2 h–24 h before `slot.start`                                                                   | 0.5               |
| Slot blocked < 2 h before `slot.start` (T8: blocked_late)                                                   | 0.1               |
| Doctor no-show (appointment status `no_show_doctor`)                                                        | 0.0               |
| Slot cancelled by clinic (not doctor's fault, verified by admin)                                            | excluded          |

**Recency weighting.** Each event carries a decay weight $w_i = 0.5^{(\text{days\_ago}/30)}$, so an event 30 days old weighs half an event today, and events beyond 60 days are dropped.

**Doctor rolling score.**

$$\text{slot\_confidence\_score} = \frac{\sum_{i} w_i \cdot e_i}{\sum_{i} w_i}$$

Clamped to `[0, 1]` and rounded to 2 decimals to fit `NUMERIC(3,2)`. The score is stored on `doctor_profiles.slot_confidence_score` and on every newly generated `slots.confidence_score` (so patients see the doctor's current score on unbooked slots).

**Update schedule.**

- **Real-time decrement** on significant events: `decrement_doctor_slot_confidence` Celery task runs on state transitions T8 (blocked_late) and T11 (no_show_doctor). It recomputes the doctor's score and writes it back; the delta is typically small but the latency matters because patients seeing stale high confidence on a no-show doctor is a trust risk.
- **Nightly recompute** (`audit.recompute_all_slot_confidence`, 03:00 UTC): iterates every active doctor and recomputes from scratch against the 60-day window. This corrects any drift and expires events that have aged out.
- **Slot generation write-through**: when new slots are created for a doctor (`generate_weekly_slots`), each slot is seeded with the doctor's current `slot_confidence_score`, not `1.00`. A newly onboarded doctor with < 10 events gets `1.00` per the grace rule.

**UI threshold.** Patients see "⚠ May vary" when `slot.confidence_score < 0.6`. Doctors see their own rolling score on the dashboard as a traffic-light: green ≥ 0.8, amber 0.6–0.8, red < 0.6.

**Anti-gaming:** `completed` does not count toward the numerator until the appointment moves into terminal state — a doctor cannot boost their score by marking future appointments complete early. Similarly, `blocked` events cannot be rescinded to undo a score hit; the history is append-only via `appointment_status_history` and `slot_block_reasons`.

#### Earnings

Completed appointments, total earnings, platform fee deduction (e.g., 8% of consultation fee), and net payout. Payouts processed weekly via Paystack Transfer to the doctor's registered bank account.

### 3.3 Clinic Admin Experience

Web-only dashboard for clinic administrative staff. Manages: multiple affiliated doctors, room/resource allocation, receptionist check-in view, appointment override, clinic-level analytics (busiest days, most-booked doctors, cancellation rate).

---

## Part 4 — Notification Architecture

The notification system is event-driven, built on Celery with Redis as the broker.

| Event                      | Triggered Notifications                                                                  |
| -------------------------- | ---------------------------------------------------------------------------------------- |
| `appointment.created`      | Confirmation to patient (push + SMS + email); new booking alert to doctor (push + email) |
| `appointment.confirmed`    | Confirmation to patient (push + SMS)                                                     |
| `appointment.reminder_24h` | Scheduled task, fires 24 hours before (push + SMS to patient)                            |
| `appointment.reminder_1h`  | Fires 1 hour before (push to patient and doctor)                                         |
| `appointment.started`      | Sends telehealth link to patient if mode is telehealth (push + SMS)                      |
| `appointment.completed`    | Triggers review request to patient (delayed 2 hours via Celery ETA)                      |
| `appointment.cancelled`    | Cancellation confirmation to both parties; triggers refund workflow if applicable        |
| `slot.blocked_last_minute` | Immediate notification to patient + priority rebooking offer                             |

**Channel routing logic:** If push fails (token expired), fall back to SMS. If SMS fails, fall back to email. The delivery log tracks every attempt.

---

## Part 5 — Search Architecture

The doctor search must be fast, contextual, and return ranked results, not just filtered lists.

### Two-Tier Search

**Tier 1 — SQL-based structured search.** Handles filtering by specialization, location (PostGIS for proximity), languages, gender, booking mode, date availability, price range. Fast, cheap, precise.

**Tier 2 — Semantic re-ranking.** For free-text queries ("doctor for my child's skin rash in Accra who speaks Twi"), the query is embedded using `text-embedding-3-small` (or a local Ollama model) and compared against pre-computed doctor profile embeddings stored in Supabase's `pgvector` extension. The top 50 results from Tier 1 are re-ranked by cosine similarity.

#### Embedding Pipeline — Authoritative Specification

**Model:** `text-embedding-3-small` (1536 dims, $0.02 / 1M tokens). The model string is stored in `doctor_profiles.embedding_model` alongside the vector, so an in-flight model swap never silently mixes dimensions. Embeddings produced by any other model are treated as stale and regenerated before use.

**Input content.** The profile text that gets embedded is a deterministic concatenation of **public, non-PII** fields only, in this order: full name, specialization labels, sub-specializations, languages spoken, consultation modes, short bio, education entries, clinic names (not addresses). Patient reviews, fee amount, GPS coordinates, and identity documents are NEVER included. The canonical builder lives in `search/embedding_builder.py::build_doctor_embedding_text(doctor_id)` and is unit-tested against a golden fixture so the PII filter cannot regress.

**Regeneration triggers.**

1. **Profile change.** A Django signal on `DoctorProfile.post_save` enqueues `trigger_profile_embedding.delay(doctor_profile_id)` whenever any embedded field changes (detected via `dirty_fields`). Non-embedded-field changes (fee, phone, etc.) do not trigger.
2. **Model upgrade.** A management command `regenerate_embeddings --model text-embedding-3-small` bulk-regenerates every row whose `embedding_model` does not match the target. Idempotent; safe to re-run.
3. **Staleness SLA.** Nightly `audit.regenerate_stale_embeddings` finds rows where `embedding_updated_at < NOW() - 90 days` and re-queues them. Prevents silent decay from out-of-band data edits.

**Cost cap.** The embedding Celery queue has a per-day token ceiling (`EMBEDDING_DAILY_TOKEN_CAP = 500_000`, ≈ $0.01/day at 1M tokens = $0.02). When exceeded, the worker defers further regenerations to the next UTC day and emits `embedding_budget_exhausted` metric. Query-time embeddings (user searches) are exempt from this cap — they are rate-limited separately in `search/ratelimit.py` (see threat model D-5) and cached in Redis with a 5-minute TTL.

**OpenAI outage fallback.**

- Query-time: if the OpenAI call fails or times out (`EMBEDDING_QUERY_TIMEOUT_MS = 800`), the search falls back to Tier 1 SQL + Postgres full-text search (`to_tsvector('english', …) @@ plainto_tsquery(query)`) ranked by `ts_rank_cd`. The response includes `"ranking_mode": "fts_fallback"` so the client can log / surface a subtle "simpler results shown" hint. Median latency degradation target: < 120 ms.
- Profile-regeneration: tasks retry with exponential backoff (60 s, 5 min, 30 min, then dead-letter). The profile remains searchable via Tier 1 the whole time — never blocks profile saves.
- A Sentry alert fires on the first dead-letter of the hour; `embedding_provider_error_rate > 5%` over 5 minutes pages on-call P2.

**PII payload audit.** The outbound HTTP call to OpenAI logs the exact payload to `embedding_request_log` (text hash + token count + truncated preview) but NEVER the patient-facing fields. A CI check (`scripts/check_embedding_payload.py`) runs against 100 golden doctor fixtures and fails the build if any regex from `config/pii_patterns.txt` (emails, Ghana phone formats, NHIS numbers) matches the constructed payload.

**Local-model escape hatch.** For air-gapped or cost-constrained environments, setting `EMBEDDING_PROVIDER=ollama` swaps the call to a local `nomic-embed-text` model (768 dims). The schema supports this via `embedding_model` gating; the IVFFlat index is rebuilt on provider switch via `REINDEX`. This is Phase 3+ work but the abstraction is in from day one.

### Ranking Signals (Weighted Composite Score)

- Semantic similarity to query (when text search is used)
- Availability match (does the doctor have slots on the patient's preferred date?)
- Rating score (a 4.8 with 200 reviews ranks higher than a 5.0 with 3 reviews)
- Distance from patient (when location is available)
- Profile completeness score
- Response rate (doctors who confirm quickly rank higher)
- Platform tenure (slight boost to new doctors for discoverability)

---

## Part 6 — Multi-Tenancy & Extensibility Design

### 6.1 Service Abstraction Layer

The platform introduces a **ServiceCategory** and **ServiceProvider** concept. Every vertical (Doctor, Barber, Mechanic) is a ServiceCategory. A Doctor is a ServiceProvider within the Medical category.

**Shared across all verticals:** `users`, `service_categories`, `service_providers` (polymorphic base), `slots`, `appointments`, `reviews`, `payments`, `notifications`.

**Vertical-specific:** `doctor_profiles` (extends service_providers), `health_timeline_entries`, `consent_grants`. These are isolated and do not pollute the shared schema.

When barber booking is ready, a new Django app `barbers` is added with `barber_profiles` and any barber-specific tables. The shared booking engine, notification system, payment system, and auth system are reused without modification.

### 6.2 Feature Flags

A lightweight feature flag system (stored in Redis, manageable via Django Admin) controls which features are live for which user segments:

- Gradual rollout of new features (e.g., telehealth to 10% of users first)
- Per-region feature gating (e.g., Paystack only in Ghana, Stripe for international)
- Vertical gating (the barber vertical can be deployed and toggled on without a code deployment)

---

## Part 7 — Phased Development Roadmap

> **Launch cut-line (ADR-0005 — authoritative for scope).** v1.0 ships the core booking loop
> **online-first** on web + mobile: auth, doctor KYC, profiles/availability/slots, **SQL search
> (not semantic)**, the atomic + idempotent booking transaction (Paystack + pay-at-desk), the
> full appointment state machine, encrypted health timeline + consent, notifications, payouts +
> WHT — **in-person consultations only**. Deferred to fast-follow: **telehealth → v1.1**;
> **the offline write/sync engine → v1.2** (mobile v1.0 is **read-through cache only** — no
> operation queue, conflict resolver, or offline booking); **semantic search → v1.3**;
> Stripe/international + family accounts → v1.x; **multi-vertical → v2+**. All security and
> compliance controls are **non-cuttable** and ship in v1.0. The compliance track (DPC, DPO,
> DPAs, legal review, KYB, DPIA, pen test) runs **in parallel from week 1** and is the real
> pacing item. v1.0 coverage bar: **100% on critical-path modules (booking, payments, auth,
> encryption, consent, state machine), ~80% elsewhere**; deferred modules carry their targets
> when they ship. The week-by-week below describes the *full* program; items tagged
> "(deferred — ADR-0005)" are not in the v1.0 launch set.

### Phase 0 — Foundation (Weeks 1–3)

Set up the monorepo. Initialize Django project with core app, identity app, custom user model, JWT auth. Initialize Next.js with App Router, Tailwind CSS v4, shadcn/ui, TanStack Query. Initialize Flutter with Riverpod, go_router, Drift, dio. Configure Supabase project (tables, RLS, Storage buckets). Set up GitHub Actions for lint, test, and build on every PR. Deploy skeleton apps to Railway (Django) and Vercel (Next.js). Establish database migration discipline (never raw SQL in production — always Django migrations).

**Non-code Phase 0 gates (must complete before any production PHI is collected):**

1. **DPC registration filed and accepted** — Veridian is registered with the Ghana Data Protection Commission per DPA 2012 §17. Registration certificate stored in the compliance folder; certificate number recorded in `platform_settings.dpc_registration_number`. Production launch is blocked until the certificate is received.
2. **DPO appointed** — named DPO on contract, contact published in the privacy notice.
3. **DPAs signed with all sub-processors** — Supabase, Railway, Paystack, Termii, Daily.co, Sentry, OpenAI, Firebase (see legal-compliance Part 1.5). A signed-DPA checklist is part of the Phase 0 sign-off.
4. **Privacy notice and terms of service v1.0 published** — versions match the `version` values that will be presented to the first patient at account creation and stored in `consent_terms_acceptances`.
5. **Paystack merchant account live and settlement bank confirmed** — required before any payment flow can accept real cards, even in staging.
6. **WORM audit archive bucket provisioned** — separate AWS account, Object Lock Compliance mode, KMS signing key created, public key committed to the repo (see RB-17).

### Phase 1 — Doctor Booking Core (Weeks 4–14)

**Weeks 4–5:** Identity & auth. Patient and doctor registration, OTP login, JWT flow, social auth (Google), role-based access, doctor KYC upload flow.

**Identifier collision policy.** `users.email` and `users.phone` are independently UNIQUE and either may be null (phone-only or email-only signup is supported). Collisions are handled as follows and every path is covered by a unit test in `tests/identity/test_collisions.py`:

- **New signup, identifier in use on an existing account:** the signup endpoint returns HTTP 409 with code `identifier_in_use`; client UX surfaces "this {phone/email} already has an account — sign in instead". The response never leaks whether the colliding account is a patient or doctor (to avoid enumeration).
- **Adding a second identifier to an account:** a logged-in user can add an email to a phone-only account (or vice versa) via `POST /account/identifiers`. The endpoint requires re-verification of the new identifier (OTP for phone, link click for email) and, if the target identifier already belongs to another account, the flow offers a challenge-based merge (see below) rather than silently failing.
- **Account merge:** initiated only by the user, only after they have successfully verified ownership of BOTH accounts in a single authenticated session. Merge consolidates appointments, health timeline, and reviews from the source account into the target; the source account is soft-deleted with `account_merged_into_id` recorded. Merges are irreversible and audit-logged with `action = 'MERGE'`.
- **Social auth with mismatched identifier:** if Google sign-in returns an email that already has a password account, the two are not auto-linked. The user must first sign in with the existing method, then link the social provider from settings. Prevents account hijacking via social provider email takeover.

**Weeks 6–7:** Doctor profiles and availability. Profile CRUD, specializations/languages (seeded taxonomy), clinic management, availability template builder, slot generation worker (Celery task that generates slots 60 days out from templates, runs nightly).

**Weeks 8–9:** Search and discovery. SQL search with filters, map integration (Mapbox GL JS on web, `flutter_map` on mobile), doctor profile page (web and mobile), doctor card components.

**Weeks 10–11:** Booking flow. Slot reservation with optimistic locking, pre-consultation form (dynamic, doctor-configured), booking confirmation, Paystack integration, `.ics` calendar export.

**Weeks 12–13:** Notifications, appointment management, post-booking UX. Full notification pipeline (Celery tasks, FCM, Termii SMS, email). Patient appointment dashboard. Doctor appointment dashboard. Reschedule and cancellation flows with fee logic.

**Week 14:** Health timeline (patient entry), reviews and ratings. *(Telehealth integration (Daily.co) deferred to v1.1 — ADR-0005.)*

### Phase 2 — Polish & Launch Readiness (Weeks 15–18)

Doctor earnings dashboard and Paystack Transfer payouts. Platform Admin panel. Performance optimization (query analysis, Redis caching for doctor profiles and slot availability). Accessibility audit (web: WCAG 2.1 AA). Security audit (OWASP Top 10 review, penetration testing). App store submission preparation. *(Semantic search deferred to v1.3; full offline sync engine to v1.2 — mobile v1.0 is read-through cache only — per ADR-0005.)*

### Phase 3 — Growth Features (Month 5+)

- **AI-powered appointment preparation** — the night before, the system generates a brief patient summary for the doctor. Patient-facing: a pre-appointment brief ("your doctor typically runs 8 minutes late on Tuesday afternoons").
- **Family accounts** — one account managing bookings for multiple family members.
- **Clinic subscriptions** — clinics pay a monthly flat fee for premium placement and analytics.
- **Doctor-initiated follow-up messaging** — structured, templated clinical follow-ups (not general chat).

### Phase 4 — Service Expansion (Month 8+)

Barber booking vertical. Mechanic booking vertical. Each adds its ServiceCategory, its provider profile app, and any domain-specific tables. The booking engine, payments, notifications, auth, and search infrastructure are inherited untouched.

---

## Part 8 — Security & Compliance

### Authentication

JWT with access token (15-minute expiry) and refresh token (30-day expiry). Refresh rotation on every use. Revocation via refresh token blocklist in Redis. Stored in HttpOnly cookie on web, `flutter_secure_storage` on mobile.

### Authorization

Django middleware enforces role checks. Supabase RLS enforces data isolation at the DB level. Every sensitive endpoint has both.

**Role re-read with Redis cache.** Role is signed into the JWT at issuance, but the JWT claim is not trusted on its own — the auth middleware re-reads `role` from a Redis cache (key `user_role:{user_id}`, TTL 60s) on every authenticated request. Cache miss triggers a single indexed lookup against `users`. When `platform_admin` changes a user's role or suspends an account, the service calls `role_cache.bust(user_id)` and revokes the user's active refresh tokens. This caps the stale-role window at 60 seconds while keeping per-request DB load ≈ 0 under steady state — without the cache, a 500 rps API issues 500 extra `SELECT role FROM users` queries per second and will hit RB-04 (connection exhaustion) quickly.

### Data Protection

Health records have an additional encryption layer. Content is encrypted with AES-256-GCM using a **per-patient key derived from a platform master key**:

```
patient_key = HKDF-SHA256(
    master = HEALTH_RECORD_MASTER_KEY,     # 256-bit, stored in Railway env / KMS
    salt   = patient_profiles.patient_key_salt,  # 32 random bytes per patient
    info   = "veridian.health_record.v1",
    length = 32
)
```

Implications:

- The master key lives in env/KMS only. The salt is stored per-patient in the database. Compromise of **either alone** does not yield plaintext.
- `patient_key` is derived at request time in memory and never persisted.
- Every `health_timeline_entries.content_encrypted` has its own random `content_iv` (GCM nonce).
- Key rotation (RB-05) rotates `HEALTH_RECORD_MASTER_KEY` — the rotation job iterates every patient, derives old and new keys, decrypts and re-encrypts each entry.
- Per-patient compromise requires the attacker to extract the master key AND the salt for that specific patient; global compromise requires the master key AND every salt. This constrains blast radius relative to a single platform-wide key.

### Additional Measures

- HTTPS everywhere (Railway handles TLS termination)
- Rate limiting: Django Ratelimit on auth endpoints (login: 5 attempts/minute per IP, OTP send: 3 per phone number per hour). Redis-backed.
- Audit logging: every write on sensitive tables (`appointments`, `health_records`, `payments`, `consent_grants`) is recorded in an append-only `audit_log` table.
- GDPR/data privacy: patient data export endpoint, account deletion (soft delete → 30-day grace → anonymize), cookie consent banner on web.

---

## Part 9 — Performance Targets & Monitoring

### Response Time Targets

| Endpoint                        | Target (p95) |
| ------------------------------- | ------------ |
| Doctor search                   | < 300ms      |
| Slot availability               | < 150ms      |
| Booking confirmation            | < 500ms      |
| Mobile app cold start           | < 2 seconds  |
| Search results from local cache | < 100ms      |
| Web LCP (4G)                    | < 1.8s       |
| Web fully interactive           | < 2.5s       |

### Monitoring Stack

| Tool                 | Purpose                                                         |
| -------------------- | --------------------------------------------------------------- |
| Sentry               | Error tracking and performance monitoring (Django + Next.js)    |
| Grafana + Prometheus | Infrastructure metrics                                          |
| PostHog              | Product analytics — funnel from search → booking → completion   |
| PagerDuty            | On-call alerts for P0 incidents (failed payments, auth outages) |

**Uptime target:** 99.9% (8.7 hours downtime/year). Achieved via Railway's auto-restart, PgBouncer connection pooling (via Supabase), and Redis sentinel.

---

## Part 10 — Design System

### Brand Identity

Veridian's visual identity is built on dark forest green as the anchor color — professional, trustworthy, connected to health and nature. The green marks actions, trust signals, and confirmations — never used gratuitously.

### Mobile (Flutter)

Full light/dark theme support. Theme toggle in Settings. System default respected on first launch.

- **Dark theme:** forest green as surface color (deep, rich backgrounds). Accent: `#2ECC8F`.
- **Light theme:** forest green as primary/CTA color against white/light gray surfaces.

### Web (Next.js + Tailwind CSS v4 + shadcn/ui)

Light-only. Forest green as primary, accent, and navigation color. White and `forest-50` (`#f0faf6`) as backgrounds. Clean, medical-grade feel — generous whitespace, high-contrast typography, no decorative clutter.

shadcn/ui components are customized via the CSS variable system to use the forest color ramp. The Tailwind config extends the default palette with the `forest` ramp as documented in Part 2.5.

### Typography

- **Web:** DM Sans (body) + Outfit (headings), loaded via `next/font`.
- **Mobile:** Equivalent via `google_fonts` package in Flutter.

### Motion

Subtle, purposeful. Page transitions: 200ms ease-out. Card expansions: 300ms spring physics. The booking confirmation screen uses a single satisfying checkmark animation (Rive or Lottie) as the emotional peak of the user journey. No gratuitous animations.

---

_End of Veridian Master Implementation Plan._
_Built for Davinix Software Solutions._

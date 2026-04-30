# Veridian — Document 2 of 10: API Contract

**Project:** Veridian All-in-One Service Booking Platform  
**Version:** 1.0.0  
**Status:** Authoritative — all Django views, Flutter data sources, and Next.js API calls derive from this document  
**Spec File:** `Veridian_openapi.yaml` (OpenAPI 3.1)  
**Base URL:** `https://api.Veridian.app/api/v1`

---

## Overview

| Metric                     | Count |
| -------------------------- | ----- |
| Total paths                | 71    |
| Total endpoints            | 87    |
| Public endpoints (no auth) | 14    |
| Protected endpoints        | 73    |
| Reusable schemas           | 37    |
| Tag groups                 | 11    |

---

## Global Conventions

### Authentication

All protected endpoints require:

```
Authorization: Bearer <access_token>
```

Access tokens expire after **15 minutes**. Refresh tokens expire after **30 days** and rotate on every use. Revoked tokens are blocklisted in Redis (durable fallback in `refresh_token_blocklist` table).

Web clients receive the refresh token as an HttpOnly, Secure, SameSite=Lax cookie. Mobile clients store it in `flutter_secure_storage`.

### Error Envelope

Every error, regardless of HTTP status code, returns this shape:

```json
{
  "error": {
    "code": "SLOT_UNAVAILABLE",
    "message": "This slot is no longer available.",
    "field_errors": {
      "slot_id": ["Slot has already been booked."]
    },
    "request_id": "550e8400-e29b-41d4-a716-446655440000"
  }
}
```

`code` is a machine-readable constant for client-side error handling. `field_errors` is present only on validation errors (HTTP 400). `request_id` maps to the Sentry trace.

### Currency

All money in responses is an object — never a bare integer:

```json
{
  "consultation_fee": {
    "amount": 15000,
    "currency_code": "GHS",
    "formatted": "GHS 150.00"
  }
}
```

`amount` is always in minor units. 15000 pesewas = GHS 150.00.

### Pagination

All list endpoints use cursor-based pagination:

```json
{
  "results": [...],
  "next_cursor": "eyJpZCI6IjEyMyJ9",
  "previous_cursor": null,
  "count": 248
}
```

Default `page_size` is 20. Maximum is 100. Pass `?cursor=<next_cursor>` to fetch the next page.

### Timestamps

All timestamps are ISO 8601 UTC strings: `"2025-06-15T09:00:00Z"`. Dates are `YYYY-MM-DD`. Clients are responsible for timezone conversion using the user's `timezone` field.

### Supabase Direct Access

Clients may read certain public data directly from Supabase (bypassing Django) for performance:

- Available slot availability (via Supabase Realtime subscription)
- Doctor profile embedding search (via Supabase pgvector RPC)

All writes and business-logic reads go through the Django API.

---

## Endpoint Reference

### Auth (14 endpoints)

| Method | Path                          | Auth   | Description                                |
| ------ | ----------------------------- | ------ | ------------------------------------------ |
| POST   | `/auth/register`              | Public | Register new user. OTP sent automatically. |
| POST   | `/auth/otp/verify`            | Public | Verify OTP → receive JWT pair.             |
| POST   | `/auth/otp/resend`            | Public | Resend OTP to phone.                       |
| POST   | `/auth/login`                 | Public | Existing user login → sends OTP.           |
| POST   | `/auth/social/{provider}`     | Public | OAuth via Google or Apple.                 |
| POST   | `/auth/token/refresh`         | Public | Rotate refresh token → new access token.   |
| POST   | `/auth/logout`                | Bearer | Revoke refresh token.                      |
| POST   | `/auth/device-tokens`         | Bearer | Register FCM/APNS push token.              |
| DELETE | `/auth/device-tokens/{token}` | Bearer | Deregister push token.                     |

**Rate limits:**

- `POST /auth/login` — 5 requests per phone per hour
- `POST /auth/otp/resend` — 3 requests per phone per hour
- `POST /auth/register` — 10 requests per IP per hour

**OTP flow:**

```
Register/Login
     │
     ▼
POST /auth/otp/verify  ──────► 200: { access_token, refresh_token, user }
     │
     ├─► 400: OTP_INVALID (wrong code)
     └─► 400: OTP_EXPIRED (> 5 minutes)
```

**Social auth flow:**

```
Client receives id_token from Google/Apple SDK
     │
     ▼
POST /auth/social/{provider}
     │
     ├─► Existing user: 200 { access_token, refresh_token, user, is_new_user: false }
     └─► New user: 200 { access_token, refresh_token, user, is_new_user: true }
         (user role must be passed in request body for new users)
```

---

### Users (8 endpoints)

| Method | Path                            | Role    | Description                                        |
| ------ | ------------------------------- | ------- | -------------------------------------------------- |
| GET    | `/users/me`                     | Any     | Get own full profile.                              |
| PATCH  | `/users/me`                     | Any     | Update name, language, timezone, avatar.           |
| POST   | `/users/me/avatar-upload-url`   | Any     | Get signed URL for direct Supabase Storage upload. |
| GET    | `/users/me/patient-profile`     | Patient | Get health profile (blood group, allergies, etc.). |
| PUT    | `/users/me/patient-profile`     | Patient | Create or fully replace health profile.            |
| POST   | `/users/me/change-phone`        | Any     | Initiate phone change → OTP to new number.         |
| POST   | `/users/me/change-phone/verify` | Any     | Confirm phone change with OTP.                     |
| POST   | `/users/me/delete-account`      | Any     | Soft delete with 30-day grace period.              |
| POST   | `/users/me/export-data`         | Any     | GDPR data export — queues job, delivers via email. |

**Avatar upload pattern (two-step):**

```
1. POST /users/me/avatar-upload-url
   → { upload_url, storage_key, expires_in_seconds: 300 }

2. Client PUTs file directly to Supabase Storage using upload_url

3. PATCH /users/me  { avatar_storage_key: "<storage_key>" }
   → Updated user profile
```

---

### Doctors — Discovery (4 endpoints, all public)

| Method | Path                    | Auth   | Description                                                  |
| ------ | ----------------------- | ------ | ------------------------------------------------------------ |
| GET    | `/doctors`              | Public | Search and filter doctors with optional semantic re-ranking. |
| GET    | `/doctors/{id}`         | Public | Full doctor profile page data.                               |
| GET    | `/doctors/{id}/slots`   | Public | Available slots for a date range (max 30 days).              |
| GET    | `/doctors/{id}/reviews` | Public | Published reviews with rating summary.                       |
| GET    | `/specializations`      | Public | Taxonomy of medical specializations.                         |

**Doctor search query params:**

| Param                    | Type    | Notes                                                                    |
| ------------------------ | ------- | ------------------------------------------------------------------------ |
| `query`                  | string  | Free-text. Activates pgvector semantic re-ranking on top 50 SQL results. |
| `specialization_slug`    | string  | e.g. `cardiology`                                                        |
| `city`                   | string  | e.g. `Accra`                                                             |
| `latitude` + `longitude` | number  | Enables PostGIS proximity ranking.                                       |
| `radius_km`              | number  | Default 10km.                                                            |
| `language_code`          | string  | BCP 47 e.g. `tw` for Twi.                                                |
| `gender`                 | enum    | Filters by doctor's gender.                                              |
| `booking_mode`           | enum    | `in_person`, `telehealth`, or `either`.                                  |
| `available_on`           | date    | Only doctors with a slot on this date.                                   |
| `max_fee`                | integer | Minor units ceiling on consultation fee.                                 |
| `sort_by`                | enum    | `relevance` (default), `rating`, `distance`, `fee_asc`, `fee_desc`.      |

**Slot response structure:**

```json
{
  "doctor_id": "uuid",
  "slots_by_date": {
    "2025-06-15": [
      {
        "id": "uuid",
        "start_time": "09:00:00",
        "end_time": "09:30:00",
        "booking_mode": "either",
        "status": "available",
        "confidence_score": 0.97
      }
    ]
  }
}
```

Slots with `confidence_score < 0.6` should display a "⚠ May vary" indicator in the UI.

---

### Doctors — Provider Management (9 endpoints)

| Method   | Path                              | Role    | Description                                           |
| -------- | --------------------------------- | ------- | ----------------------------------------------------- |
| GET      | `/doctors/me/profile`             | Doctor  | Own full profile.                                     |
| PATCH    | `/doctors/me/profile`             | Doctor  | Update bio, languages, qualifications, active status. |
| POST     | `/doctors/me/kyc`                 | Doctor  | Submit license for platform review.                   |
| GET      | `/doctors/me/affiliations`        | Doctor  | List clinic affiliations.                             |
| POST     | `/doctors/me/affiliations`        | Doctor  | Add a clinic affiliation with fee config.             |
| PATCH    | `/doctors/me/affiliations/{id}`   | Doctor  | Update room, fee, or active status.                   |
| GET/POST | `/patients/me/saved-doctors`      | Patient | Save/list saved doctors.                              |
| DELETE   | `/patients/me/saved-doctors/{id}` | Patient | Unsave a doctor.                                      |

---

### Availability (8 endpoints)

| Method | Path                                      | Role         | Description                                           |
| ------ | ----------------------------------------- | ------------ | ----------------------------------------------------- |
| GET    | `/doctors/me/availability-templates`      | Doctor       | List weekly recurring templates.                      |
| POST   | `/doctors/me/availability-templates`      | Doctor       | Create template → triggers immediate slot generation. |
| PATCH  | `/doctors/me/availability-templates/{id}` | Doctor       | Update template (future slots only).                  |
| DELETE | `/doctors/me/availability-templates/{id}` | Doctor       | Deactivate template.                                  |
| GET    | `/doctors/me/slots`                       | Doctor       | View own slots (all statuses, date range).            |
| POST   | `/slots/{id}/block`                       | Doctor/Admin | Block a specific slot. Fails if slot is `booked`.     |
| POST   | `/slots/{id}/unblock`                     | Doctor/Admin | Unblock a blocked slot.                               |

**Slot generation flow:**

```
Doctor creates availability_template
          │
          ▼
Django fires immediate Celery task: generate_slots_for_template(template_id)
          │
          ▼
Nightly Celery Beat task (00:30 WAT): generate_slots_for_all_active_templates()
          │
          ▼
Slots generated 60 days out with UNIQUE(doctor_id, slot_date, start_time) guard
```

**Template update behaviour:** Changes to a template affect only future slot generation. Already-generated future slots are unchanged. To change existing slots, block them individually or in bulk.

---

### Appointments (10 endpoints)

| Method | Path                            | Role           | Description                            |
| ------ | ------------------------------- | -------------- | -------------------------------------- |
| GET    | `/appointments`                 | Any            | List own appointments (role-filtered). |
| POST   | `/appointments`                 | Patient        | Book an appointment.                   |
| GET    | `/appointments/{id}`            | Patient/Doctor | Full appointment detail.               |
| POST   | `/appointments/{id}/confirm`    | Doctor         | Confirm a requested appointment.       |
| POST   | `/appointments/{id}/start`      | Doctor         | Start the consultation.                |
| POST   | `/appointments/{id}/complete`   | Doctor         | Complete the consultation.             |
| POST   | `/appointments/{id}/cancel`     | Any            | Cancel with reason.                    |
| POST   | `/appointments/{id}/reschedule` | Patient/Doctor | Move to new slot atomically.           |
| POST   | `/appointments/{id}/no-show`    | Doctor/Admin   | Mark no-show.                          |
| GET    | `/appointments/{id}/ics`        | Patient/Doctor | Download `.ics` calendar file.         |

**Booking response (POST /appointments):**

```json
{
  "appointment": { ... AppointmentSummary },
  "payment": {
    "provider": "paystack",
    "authorization_url": "https://checkout.paystack.com/...",
    "access_code": "ACCESS_CODE_FOR_MOBILE_SDK",
    "reference": "MBK-20250615-XXXX",
    "expires_at": "2025-06-15T09:10:00Z"
  }
}
```

For pay-at-desk bookings, `payment` is `null` and appointment moves directly to `confirmed`.

**Cancellation refund logic:**

| Canceller | Timing                                 | Refund                              |
| --------- | -------------------------------------- | ----------------------------------- |
| Patient   | Within free window (e.g. > 24h before) | Full refund                         |
| Patient   | Outside free window                    | Per clinic policy (partial or none) |
| Doctor    | Any time                               | Full refund always                  |
| Platform  | Any time                               | Full refund always                  |

**Telehealth URL visibility rule:** `telehealth_patient_url` is only populated in the `AppointmentFull` response when `NOW() >= slot.start_time - 15 minutes`. This is enforced at the serializer level, not the database level.

---

### Health Records (10 endpoints)

| Method | Path                                      | Role    | Description                                       |
| ------ | ----------------------------------------- | ------- | ------------------------------------------------- |
| GET    | `/patients/me/timeline`                   | Patient | Own decrypted health timeline.                    |
| POST   | `/patients/me/timeline`                   | Patient | Add symptom log, patient note, or allergy record. |
| PATCH  | `/patients/me/timeline/{id}`              | Patient | Update own entry.                                 |
| DELETE | `/patients/me/timeline/{id}`              | Patient | Soft-delete own entry.                            |
| POST   | `/patients/me/timeline/export`            | Patient | Queue PDF export via WeasyPrint.                  |
| GET    | `/patients/{patient_id}/timeline`         | Doctor  | Read patient's shared entries (consent required). |
| POST   | `/appointments/{id}/diagnosis`            | Doctor  | Add diagnosis note to an appointment.             |
| GET    | `/patients/me/consent-grants`             | Patient | List active consent grants.                       |
| POST   | `/patients/me/consent-grants`             | Patient | Grant a doctor timeline access.                   |
| POST   | `/patients/me/consent-grants/{id}/revoke` | Patient | Revoke a consent grant.                           |

**Encryption transparency:** The API always returns `content` as a decrypted JSON object. Encryption/decryption is invisible to clients. The database stores only ciphertext.

**Consent enforcement (doctor reads patient timeline):**

```
GET /patients/{patient_id}/timeline
          │
          ▼
Django checks consent_grants table:
  - granted_to_doctor = current doctor's profile
  - patient_id = path param patient_id
  - revoked_at IS NULL
  - expires_at IS NULL OR expires_at > NOW()
          │
    ├─► No valid grant → 403 CONSENT_REQUIRED
    └─► Valid grant → filtered timeline (shared entries only)
```

**Doctor-authored entry types:** Only `diagnosis_note`, `prescription`, `lab_result`, `vaccination` can be authored by a doctor. These are created via `POST /appointments/{id}/diagnosis` — not the patient timeline endpoint.

---

### Payments (7 endpoints)

| Method | Path                          | Auth          | Description                                    |
| ------ | ----------------------------- | ------------- | ---------------------------------------------- |
| POST   | `/payments/verify`            | Bearer        | Verify payment after Paystack/Stripe checkout. |
| POST   | `/payments/webhooks/paystack` | Public (HMAC) | Paystack webhook receiver.                     |
| POST   | `/payments/webhooks/stripe`   | Public (sig)  | Stripe webhook receiver.                       |
| GET    | `/payments/history`           | Bearer        | Own payment transaction history.               |
| GET    | `/doctors/me/earnings`        | Doctor        | Earnings summary and payout history.           |
| GET    | `/doctors/me/bank-accounts`   | Doctor        | List bank accounts (last 4 digits only).       |
| POST   | `/doctors/me/bank-accounts`   | Doctor        | Add bank account for payouts.                  |

**Payment lifecycle (Paystack):**

```
POST /appointments → { payment.access_code }
          │
          ▼
Mobile: Paystack Flutter SDK charges card
Web: redirect to payment.authorization_url
          │
          ▼
POST /payments/verify { reference: "MBK-...", provider: "paystack" }
          │
    ├─► 200: payment captured → appointment confirmed
    └─► 400: PAYMENT_FAILED → slot released after TTL

In parallel: Paystack sends webhook to /payments/webhooks/paystack
  (validated via x-paystack-signature HMAC)
  (processed async via Celery — idempotent)
```

**Account number security:** Bank account numbers are encrypted at application level. The API never returns a full account number — only `account_number_last4` (last 4 digits).

---

### Reviews (3 endpoints)

| Method | Path                        | Role    | Description                              |
| ------ | --------------------------- | ------- | ---------------------------------------- |
| POST   | `/appointments/{id}/review` | Patient | Submit post-appointment review.          |
| POST   | `/reviews/{id}/reply`       | Doctor  | Reply to a review (one reply, no edits). |
| POST   | `/reviews/{id}/flag`        | Any     | Flag review for moderation.              |

Reviews start in `pending` status. An async Celery task runs basic moderation (profanity filter, length check) and auto-publishes clean reviews within 5 minutes. Flagged reviews go to the platform admin queue.

On each new review publication, the Django signal recalculates all four rating averages on `doctor_profiles` atomically.

---

### Notifications (5 endpoints)

| Method | Path                         | Role | Description                                |
| ------ | ---------------------------- | ---- | ------------------------------------------ |
| GET    | `/notifications/preferences` | Any  | Get per-channel, per-category preferences. |
| PUT    | `/notifications/preferences` | Any  | Bulk replace preferences.                  |
| GET    | `/notifications/history`     | Any  | In-app notification feed.                  |
| POST   | `/notifications/{id}/read`   | Any  | Mark one as read.                          |
| POST   | `/notifications/read-all`    | Any  | Mark all as read.                          |

---

### Admin (5 endpoints)

| Method | Path                           | Role           | Description                                |
| ------ | ------------------------------ | -------------- | ------------------------------------------ |
| POST   | `/admin/doctors/{id}/verify`   | Platform Admin | Approve, reject, or suspend a doctor.      |
| POST   | `/admin/reviews/{id}/moderate` | Platform Admin | Publish, remove, or unflag a review.       |
| POST   | `/admin/payouts/trigger`       | Platform Admin | Manual payout batch with dry-run option.   |
| GET    | `/admin/feature-flags`         | Platform Admin | List all feature flags.                    |
| PATCH  | `/admin/feature-flags/{key}`   | Platform Admin | Toggle a feature flag or adjust rollout %. |
| GET    | `/health`                      | Public         | Service health check (DB, Redis, Celery).  |

---

## Error Code Reference

| Code                        | HTTP | Triggered by                                  |
| --------------------------- | ---- | --------------------------------------------- |
| `VALIDATION_ERROR`          | 400  | Invalid request body fields                   |
| `OTP_INVALID`               | 400  | Wrong or expired OTP                          |
| `OTP_EXPIRED`               | 400  | OTP > 5 minutes old                           |
| `PAYMENT_FAILED`            | 400  | Provider reports payment not successful       |
| `SLOT_UNAVAILABLE`          | 409  | Slot taken between selection and booking      |
| `SLOT_ALREADY_BOOKED`       | 409  | Attempt to block a booked slot                |
| `AUTHENTICATION_REQUIRED`   | 401  | Missing or invalid Bearer token               |
| `REFRESH_TOKEN_INVALID`     | 401  | Expired or revoked refresh token              |
| `PERMISSION_DENIED`         | 403  | Role insufficient for this action             |
| `CONSENT_REQUIRED`          | 403  | Doctor lacks patient consent to read timeline |
| `NOT_FOUND`                 | 404  | Resource does not exist or is soft-deleted    |
| `PHONE_ALREADY_EXISTS`      | 409  | Registration with existing phone              |
| `REVIEW_ALREADY_SUBMITTED`  | 409  | Second review attempt on same appointment     |
| `REPLY_ALREADY_SUBMITTED`   | 409  | Second doctor reply attempt                   |
| `OUTSIDE_RESCHEDULE_WINDOW` | 409  | Reschedule attempt past policy deadline       |
| `RATE_LIMIT_EXCEEDED`       | 429  | Too many requests (auth endpoints)            |
| `DOCTOR_NOT_VERIFIED`       | 403  | Action requires verified doctor profile       |

---

## Role-Based Access Summary

| Endpoint Group                     | Patient  | Doctor             | Clinic Admin | Platform Admin |
| ---------------------------------- | -------- | ------------------ | ------------ | -------------- |
| Auth                               | ✓        | ✓                  | ✓            | ✓              |
| Own user profile                   | ✓        | ✓                  | ✓            | ✓              |
| Patient health profile             | ✓        | —                  | —            | —              |
| Doctor search & profiles           | ✓ (read) | ✓ (read+write own) | ✓ (read)     | ✓              |
| Booking appointments               | ✓        | —                  | —            | —              |
| Confirming / starting / completing | —        | ✓                  | —            | —              |
| Cancelling appointments            | ✓ (own)  | ✓ (own)            | ✓ (clinic's) | ✓              |
| Health timeline                    | ✓ (own)  | ✓ (with consent)   | —            | —              |
| Adding diagnosis notes             | —        | ✓                  | —            | —              |
| Earnings & payouts                 | —        | ✓                  | —            | ✓              |
| Doctor KYC review                  | —        | —                  | —            | ✓              |
| Feature flags                      | —        | —                  | —            | ✓              |
| Review moderation                  | —        | —                  | —            | ✓              |

---

## Django Implementation Notes

### URL routing (urls.py structure)

```python
# api/v1/urls.py
urlpatterns = [
    path('auth/', include('identity.urls')),
    path('users/', include('users.urls')),
    path('doctors/', include('doctors.urls')),
    path('patients/', include('patients.urls')),
    path('clinics/', include('clinics.urls')),
    path('appointments/', include('appointments.urls')),
    path('slots/', include('slots.urls')),
    path('payments/', include('payments.urls')),
    path('notifications/', include('notifications.urls')),
    path('reviews/', include('reviews.urls')),
    path('specializations/', include('specializations.urls')),
    path('admin/', include('admin_portal.urls')),
    path('health', HealthCheckView.as_view()),
]
```

### Serializer discipline

- Request serializers validate input only (never expose internal fields)
- Response serializers shape output only (never accept input)
- Never use the same serializer for both directions
- `SerializerMethodField` for computed fields (e.g. `next_available_slot`, `telehealth_patient_url` with time-gate)

### Permission classes

```python
# Custom permission classes
IsPatient          # role == 'patient'
IsDoctor           # role == 'doctor' AND verification_status == 'verified'
IsDoctorAny        # role == 'doctor' (any verification status — for own profile endpoints)
IsClinicAdmin      # role == 'clinic_admin'
IsPlatformAdmin    # role == 'platform_admin'
IsOwnerOrAdmin     # obj.user_id == request.user OR IsPlatformAdmin
IsAppointmentParty # appointment.patient_id == user OR appointment.doctor profile user == user
```

### Atomic booking

```python
# appointments/services.py
@transaction.atomic
def create_appointment(patient, slot_id, booking_mode, responses, provider):
    slot = Slot.objects.select_for_update().get(id=slot_id)
    if slot.status != SlotStatus.AVAILABLE:
        raise SlotUnavailableError()
    slot.status = SlotStatus.RESERVED
    slot.reserved_at = now()
    slot.reservation_expires_at = now() + timedelta(minutes=10)
    slot.save()
    appt = Appointment.objects.create(
        slot=slot,
        patient=patient,
        doctor_profile=slot.doctor_profile,
        status=AppointmentStatus.REQUESTED,
        booking_mode=booking_mode,
        pre_consultation_responses=responses,
        consultation_fee=slot.clinic_affiliation.consultation_fee,
        currency_code=slot.clinic_affiliation.currency_code,
    )
    AppointmentStatusHistory.objects.create(
        appointment=appt, from_status=None, to_status=AppointmentStatus.REQUESTED, actor=patient
    )
    payment = initiate_payment(appt, provider)
    notify_booking_created.delay(appt.id)
    return appt, payment
```

---

## Flutter Client Notes

### Repository pattern for API calls

```dart
// appointments/data/remote_data_source.dart
class AppointmentRemoteDataSource {
  final Dio _dio;

  Future<AppointmentSummary> createAppointment(CreateAppointmentRequest req) async {
    final response = await _dio.post('/appointments', data: req.toJson());
    return AppointmentSummary.fromJson(response.data['appointment']);
  }

  Future<List<AppointmentSummary>> getAppointments({String? cursor}) async {
    final response = await _dio.get('/appointments',
      queryParameters: cursor != null ? {'cursor': cursor} : null);
    return (response.data['results'] as List)
        .map((e) => AppointmentSummary.fromJson(e))
        .toList();
  }
}
```

### Offline queue for appointments

```dart
// When offline, appointments are queued locally in Drift
// and flushed when connectivity restores

class OfflineOperationQueue {
  Future<void> enqueueBooking(CreateAppointmentRequest req) async {
    await _db.offlineOperationsDao.insert(OfflineOperation(
      type: 'CREATE_APPOINTMENT',
      payload: jsonEncode(req.toJson()),
      createdAt: DateTime.now(),
    ));
  }

  Future<void> flush(AppointmentRemoteDataSource remote) async {
    final ops = await _db.offlineOperationsDao.getPending();
    for (final op in ops) {
      try {
        await _dispatch(op, remote);
        await _db.offlineOperationsDao.delete(op);
      } on SlotUnavailableError {
        await _notifyUser('Your queued booking for ${op.doctorName} is no longer available.');
        await _db.offlineOperationsDao.delete(op);
      }
    }
  }
}
```

### Supabase Realtime for slot availability

```dart
// Subscribes to slot status changes for a specific doctor
_supabase
  .from('slots')
  .stream(primaryKey: ['id'])
  .eq('doctor_profile_id', doctorId)
  .gte('slot_date', DateTime.now().toIso8601String())
  .listen((data) {
    ref.read(slotsProvider(doctorId).notifier).updateSlots(data);
  });
```

---

## Next.js Client Notes

### TanStack Query key conventions

```ts
// lib/query-keys.ts
export const queryKeys = {
  doctors: {
    search: (params: DoctorSearchParams) => ["doctors", "search", params],
    detail: (id: string) => ["doctors", id],
    slots: (id: string, from: string, to: string) => [
      "doctors",
      id,
      "slots",
      from,
      to,
    ],
    reviews: (id: string) => ["doctors", id, "reviews"],
  },
  appointments: {
    list: (filters: AppointmentFilters) => ["appointments", filters],
    detail: (id: string) => ["appointments", id],
  },
  timeline: {
    list: (filters: TimelineFilters) => ["timeline", filters],
  },
};
```

### Server component prefetching

```ts
// app/(marketing)/doctors/[slug]/page.tsx
export default async function DoctorProfilePage({ params }) {
  const queryClient = new QueryClient()

  // Prefetch on the server for SEO and instant first paint
  await queryClient.prefetchQuery({
    queryKey: queryKeys.doctors.detail(params.slug),
    queryFn: () => getDoctorProfile(params.slug),
  })

  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <DoctorProfileClient slug={params.slug} />
    </HydrationBoundary>
  )
}
```

---

## Files Produced

| File                       | Description                                                               |
| -------------------------- | ------------------------------------------------------------------------- |
| `Veridian_openapi.yaml`    | Full OpenAPI 3.1 specification — 87 endpoints, 37 schemas, 3,834 lines    |
| `Veridian-api-contract.md` | This document — endpoint reference, conventions, and implementation notes |

---

\*Next document: **Document 3 of 10 — State Machine Definitions\***  
_Appointment lifecycle, slot lifecycle, KYC flow, and payment flow — every state, transition, guard condition, and side effect._

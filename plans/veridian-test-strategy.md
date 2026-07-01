# Veridian — Document 7 of 10: Test Strategy

**Project:** Veridian All-in-One Service Booking Platform  
**Version:** 1.0.0  
**Status:** Authoritative — all CI/CD gates, coverage requirements, and QA processes derive from this document  
**Applies to:** Django API, Flutter mobile, Next.js web

---

## Philosophy

Testing in Veridian follows three non-negotiable principles:

**1. Trust the pyramid.** Unit tests are fast, numerous, and cheap. Integration tests are slower and fewer. E2E tests are slowest and smallest in number. Inverting this pyramid (relying on E2E for coverage the unit tests should provide) makes the CI pipeline slow, flaky, and expensive to maintain.

**2. Test behaviour, not implementation.** Tests should break when the product behaves incorrectly — not when the code is refactored. A test that couples to internal method names or database field names is a maintenance liability. Tests couple to the API contract (for Django), the public widget interface (for Flutter), and the rendered output (for Next.js).

**3. Production data never enters test environments.** Patient health data is sensitive. Test data is synthetic, generated from factories, and contains no real patient information. No test ever calls a live payment provider, a live SMS gateway, or a live telehealth room.

---

## Coverage Targets

| Platform | Layer                                     | Minimum coverage                          | Measurement                     |
| -------- | ----------------------------------------- | ----------------------------------------- | ------------------------------- |
| Django   | Unit (service layer + models)             | 90% line coverage                         | `pytest-cov`                    |
| Django   | Integration (API endpoints)               | 100% of endpoints have at least one test  | Manual checklist + `pytest-cov` |
| Django   | Critical paths                            | 100% branch coverage                      | `pytest-cov --branch`           |
| Flutter  | Unit (use cases, repositories, resolvers) | 85% line coverage                         | `flutter test --coverage`       |
| Flutter  | Widget tests                              | All screens have at least one widget test | Manual checklist                |
| Flutter  | Integration                               | All critical user journeys covered        | Manual checklist                |
| Next.js  | Unit (utility functions, API clients)     | 80% line coverage                         | `vitest --coverage`             |
| Next.js  | Component tests                           | All page-level components tested          | Manual checklist                |
| Next.js  | E2E (Playwright)                          | All user journeys in the booking funnel   | Manual checklist                |

**Critical paths** (require 100% branch coverage in Django):

- Appointment creation (the booking transaction)
- Slot reservation and expiry
- Payment verification and webhook handling
- Appointment status transitions
- Health timeline access with consent check
- JWT issuance and refresh rotation

---

## Django Testing

### Test Stack

| Tool                       | Purpose                                                       |
| -------------------------- | ------------------------------------------------------------- |
| `pytest` + `pytest-django` | Test runner and Django integration                            |
| `pytest-cov`               | Coverage measurement                                          |
| `factory_boy`              | Test data factories                                           |
| `faker`                    | Realistic fake data (Ghanaian context)                        |
| `freezegun`                | Time-freezing for TTL and scheduling tests                    |
| `responses`                | Mock external HTTP calls (Paystack, Termii, Daily.co, OpenAI) |
| `celery[pytest]`           | Test Celery tasks in eager mode                               |
| `model_bakery`             | Quick model instance creation for simple cases                |

### Project Structure

```
api/
├── conftest.py                    # Shared fixtures: db, client, users, tokens
├── core/
│   └── tests/
│       └── test_middleware.py
├── identity/
│   └── tests/
│       ├── test_registration.py
│       ├── test_otp.py
│       ├── test_jwt.py
│       └── test_social_auth.py
├── doctors/
│   └── tests/
│       ├── test_profile.py
│       ├── test_kyc.py
│       ├── test_search.py
│       └── test_availability.py
├── appointments/
│   └── tests/
│       ├── test_booking.py        # Most critical — covers the booking transaction
│       ├── test_state_machine.py  # Every transition from Document 3
│       ├── test_cancellation.py
│       ├── test_reschedule.py
│       └── test_no_show.py
├── slots/
│   └── tests/
│       ├── test_slot_generation.py
│       ├── test_slot_lifecycle.py
│       └── test_reservation_expiry.py
├── health_records/
│   └── tests/
│       ├── test_timeline.py
│       ├── test_consent.py
│       └── test_encryption.py
├── payments/
│   └── tests/
│       ├── test_paystack.py
│       ├── test_webhooks.py
│       └── test_refunds.py
└── notifications/
    └── tests/
        └── test_tasks.py
```

### Factories

```python
# conftest.py / factories.py

import factory
from faker import Faker
from factory.django import DjangoModelFactory

fake = Faker('en_GH')  # Ghanaian locale for realistic test data

class UserFactory(DjangoModelFactory):
    class Meta:
        model = 'identity.User'

    full_name = factory.LazyAttribute(lambda _: fake.name())
    phone = factory.LazyAttribute(lambda _: f'+233{fake.numerify("2#########")}')
    phone_verified = True
    role = 'patient'
    preferred_language = 'en'
    timezone = 'Africa/Accra'
    is_active = True

class DoctorUserFactory(UserFactory):
    role = 'doctor'

class DoctorProfileFactory(DjangoModelFactory):
    class Meta:
        model = 'doctors.DoctorProfile'

    user = factory.SubFactory(DoctorUserFactory)
    verification_status = 'verified'
    is_profile_active = True
    accepts_new_patients = True
    license_number = factory.LazyAttribute(lambda _: fake.numerify('GH-MD-#####'))
    license_issuing_council = 'Ghana Medical and Dental Council'
    slot_confidence_score = 1.00
    rating_avg = 4.50
    rating_count = 20

class ClinicFactory(DjangoModelFactory):
    class Meta:
        model = 'clinics.Clinic'

    name = factory.LazyAttribute(lambda _: f'{fake.last_name()} Medical Centre')
    city = factory.Iterator(['Accra', 'Kumasi', 'Tamale', 'Cape Coast'])
    country_code = 'GH'
    verification_status = 'verified'
    is_active = True

class ClinicAffiliationFactory(DjangoModelFactory):
    class Meta:
        model = 'doctors.ClinicAffiliation'

    doctor_profile = factory.SubFactory(DoctorProfileFactory)
    clinic = factory.SubFactory(ClinicFactory)
    consultation_fee = 15000  # GHS 150.00 in pesewas
    currency_code = 'GHS'
    is_active = True
    is_primary_clinic = True

class SlotFactory(DjangoModelFactory):
    class Meta:
        model = 'slots.Slot'

    doctor_profile = factory.SubFactory(DoctorProfileFactory)
    slot_date = factory.LazyFunction(lambda: date.today() + timedelta(days=1))
    start_time = time(9, 0)
    end_time = time(9, 30)
    booking_mode = 'either'
    status = 'available'
    confidence_score = 1.00

class AppointmentFactory(DjangoModelFactory):
    class Meta:
        model = 'appointments.Appointment'

    slot = factory.SubFactory(SlotFactory)
    patient = factory.SubFactory(UserFactory)
    doctor_profile = factory.LazyAttribute(lambda o: o.slot.doctor_profile)
    status = 'confirmed'
    booking_mode = 'in_person'
    consultation_fee = 15000
    currency_code = 'GHS'
    platform_fee_pct = 8.00
    pre_consultation_responses = {'platform-default-0001': 'Routine checkup'}
```

### Unit Tests — Service Layer

```python
# appointments/tests/test_booking.py

import pytest
from unittest.mock import patch
from django.test import TestCase
from freezegun import freeze_time
from appointments.services import create_appointment
from appointments.exceptions import SlotUnavailableError
from .factories import UserFactory, SlotFactory, DoctorProfileFactory

class TestCreateAppointment:

    @pytest.fixture(autouse=True)
    def setup(self, db):
        self.patient = UserFactory(role='patient')
        self.slot = SlotFactory(status='available')

    def test_successful_booking_reserves_slot(self):
        appt, _ = create_appointment(
            patient=self.patient,
            slot_id=self.slot.id,
            booking_mode='in_person',
            responses={'platform-default-0001': 'Cough'},
            provider='paystack',
        )
        self.slot.refresh_from_db()
        assert self.slot.status == 'reserved'
        assert appt.status == 'requested'

    def test_concurrent_booking_raises_slot_unavailable(self):
        """Only one of two concurrent bookings should succeed."""
        import threading
        results = []

        def attempt_booking():
            try:
                appt, _ = create_appointment(
                    patient=UserFactory(role='patient'),
                    slot_id=self.slot.id,
                    booking_mode='in_person',
                    responses={},
                    provider='paystack',
                )
                results.append('success')
            except SlotUnavailableError:
                results.append('conflict')

        t1 = threading.Thread(target=attempt_booking)
        t2 = threading.Thread(target=attempt_booking)
        t1.start(); t2.start()
        t1.join(); t2.join()

        assert results.count('success') == 1
        assert results.count('conflict') == 1

    def test_booking_already_reserved_slot_raises(self):
        self.slot.status = 'reserved'
        self.slot.save()
        with pytest.raises(SlotUnavailableError):
            create_appointment(
                patient=self.patient,
                slot_id=self.slot.id,
                booking_mode='in_person',
                responses={},
                provider='paystack',
            )

    def test_booking_past_slot_raises(self):
        self.slot.slot_date = date.today() - timedelta(days=1)
        self.slot.save()
        with pytest.raises(SlotUnavailableError, match='past'):
            create_appointment(self.patient, self.slot.id, 'in_person', {}, 'paystack')

    def test_incompatible_booking_mode_raises(self):
        self.slot.booking_mode = 'in_person'
        self.slot.save()
        with pytest.raises(ValueError, match='INVALID_BOOKING_MODE'):
            create_appointment(self.patient, self.slot.id, 'telehealth', {}, 'paystack')

    def test_status_history_created_on_booking(self):
        appt, _ = create_appointment(
            self.patient, self.slot.id, 'in_person', {}, 'paystack'
        )
        history = appt.status_history.all()
        assert history.count() == 1
        assert history.first().from_status is None
        assert history.first().to_status == 'requested'
        assert history.first().actor == self.patient

    @patch('appointments.services.notify_booking_created.delay')
    def test_notification_task_fired_on_booking(self, mock_notify):
        appt, _ = create_appointment(
            self.patient, self.slot.id, 'in_person', {}, 'paystack'
        )
        mock_notify.assert_called_once_with(appt.id)
```

### State Machine Tests

```python
# appointments/tests/test_state_machine.py

class TestAppointmentStateMachine:
    """Tests every valid and invalid transition from Document 3."""

    # --- Valid transitions ---

    def test_T2_requested_to_confirmed_by_doctor(self, db, confirmed_appointment):
        appt = AppointmentFactory(status='requested')
        result = confirm_appointment(doctor_user=appt.doctor_profile.user, appointment_id=appt.id)
        assert result.status == 'confirmed'
        assert appt.slot.status == 'booked'

    def test_T3_confirmed_to_in_progress(self, db):
        appt = AppointmentFactory(status='confirmed')
        with freeze_time(datetime.combine(appt.slot.slot_date, appt.slot.start_time)):
            result = start_appointment(appt.doctor_profile.user, appt.id)
        assert result.status == 'in_progress'
        assert result.actual_start_time is not None

    def test_T4_in_progress_to_completed(self, db):
        appt = AppointmentFactory(status='in_progress', actual_start_time=timezone.now())
        result = complete_appointment(appt.doctor_profile.user, appt.id)
        assert result.status == 'completed'
        assert result.actual_end_time is not None

    def test_T6_confirmed_cancellation_full_refund_within_window(self, db):
        """Patient cancels 36 hours before — should get full refund."""
        slot_time = timezone.now() + timedelta(hours=36)
        appt = AppointmentFactory(status='confirmed')
        appt.slot.slot_date = slot_time.date()
        appt.slot.start_time = slot_time.time()
        appt.slot.save()
        result, refund = cancel_appointment(appt.patient, appt.id, 'Changed my mind')
        assert result.status == 'cancelled_by_patient'
        assert refund['policy'] == 'full_refund'
        assert refund['amount'] == appt.consultation_fee

    def test_T6_confirmed_cancellation_no_refund_outside_window(self, db):
        """Patient cancels 2 hours before — no refund."""
        slot_time = timezone.now() + timedelta(hours=2)
        appt = AppointmentFactory(status='confirmed')
        appt.slot.slot_date = slot_time.date()
        appt.slot.start_time = slot_time.time()
        appt.slot.save()
        result, refund = cancel_appointment(appt.patient, appt.id, 'Emergency')
        assert result.status == 'cancelled_by_patient'
        assert refund['policy'] == 'no_refund'

    # --- Invalid transitions (forbidden) ---

    def test_cannot_complete_without_starting(self, db):
        appt = AppointmentFactory(status='confirmed')
        with pytest.raises(InvalidStateTransitionError):
            complete_appointment(appt.doctor_profile.user, appt.id)

    def test_cannot_cancel_completed_appointment(self, db):
        appt = AppointmentFactory(status='completed')
        with pytest.raises(InvalidStateTransitionError, match='APPOINTMENT_ALREADY_TERMINAL'):
            cancel_appointment(appt.patient, appt.id, 'Reason')

    def test_cannot_start_too_early(self, db):
        appt = AppointmentFactory(status='confirmed')
        appt.slot.slot_date = date.today() + timedelta(days=2)
        appt.slot.save()
        with pytest.raises(InvalidStateTransitionError, match='TOO_EARLY_TO_START'):
            start_appointment(appt.doctor_profile.user, appt.id)

    def test_patient_cannot_confirm_appointment(self, db):
        appt = AppointmentFactory(status='requested')
        with pytest.raises(PermissionDenied):
            confirm_appointment(doctor_user=appt.patient, appointment_id=appt.id)

    def test_wrong_doctor_cannot_start_appointment(self, db):
        appt = AppointmentFactory(status='confirmed')
        other_doctor = DoctorUserFactory()
        with pytest.raises(PermissionDenied):
            start_appointment(other_doctor, appt.id)
```

### Integration Tests — API Endpoints

```python
# appointments/tests/test_booking_api.py

class TestBookingAPI:
    """Integration tests — tests the full HTTP request/response cycle."""

    def test_POST_appointments_creates_appointment(self, api_client, patient_token, available_slot):
        api_client.credentials(HTTP_AUTHORIZATION=f'Bearer {patient_token}')
        response = api_client.post('/api/v1/appointments', {
            'slot_id': str(available_slot.id),
            'booking_mode': 'in_person',
            'pre_consultation_responses': {'platform-default-0001': 'Headache'},
            'payment_provider': 'paystack',
        })
        assert response.status_code == 201
        data = response.json()
        assert data['appointment']['status'] == 'requested'
        assert data['payment']['provider'] == 'paystack'
        assert 'authorization_url' in data['payment']

    def test_POST_appointments_returns_409_for_taken_slot(self, api_client, patient_token, reserved_slot):
        api_client.credentials(HTTP_AUTHORIZATION=f'Bearer {patient_token}')
        response = api_client.post('/api/v1/appointments', {
            'slot_id': str(reserved_slot.id),
            'booking_mode': 'in_person',
            'pre_consultation_responses': {},
        })
        assert response.status_code == 409
        assert response.json()['error']['code'] == 'SLOT_UNAVAILABLE'

    def test_GET_appointments_patient_sees_only_own(self, api_client):
        patient1 = UserFactory(role='patient')
        patient2 = UserFactory(role='patient')
        AppointmentFactory(patient=patient1, status='confirmed')
        AppointmentFactory(patient=patient2, status='confirmed')

        api_client.force_authenticate(patient1)
        response = api_client.get('/api/v1/appointments')

        assert response.status_code == 200
        ids = [a['id'] for a in response.json()['results']]
        # Only patient1's appointment returned — not patient2's
        assert len(ids) == 1

    def test_GET_appointment_detail_returns_403_for_other_patient(self, api_client):
        appt = AppointmentFactory(status='confirmed')
        other_patient = UserFactory(role='patient')

        api_client.force_authenticate(other_patient)
        response = api_client.get(f'/api/v1/appointments/{appt.id}')
        assert response.status_code == 403

    def test_unauthenticated_booking_returns_401(self, api_client, available_slot):
        response = api_client.post('/api/v1/appointments', {'slot_id': str(available_slot.id)})
        assert response.status_code == 401
```

### Payment Tests

```python
# payments/tests/test_webhooks.py

class TestPaystackWebhook:

    @patch('payments.services.confirm_appointment')
    def test_valid_charge_success_webhook_confirms_appointment(
        self, mock_confirm, api_client, pending_payment
    ):
        payload = {
            'event': 'charge.success',
            'data': {
                'reference': pending_payment.provider_reference,
                'amount': pending_payment.amount,
                'status': 'success',
            }
        }
        sig = self._sign(payload)
        response = api_client.post(
            '/api/v1/payments/webhooks/paystack',
            payload,
            content_type='application/json',
            HTTP_X_PAYSTACK_SIGNATURE=sig,
        )
        assert response.status_code == 200
        mock_confirm.assert_called_once()

    def test_invalid_signature_returns_400(self, api_client):
        response = api_client.post(
            '/api/v1/payments/webhooks/paystack',
            {'event': 'charge.success'},
            content_type='application/json',
            HTTP_X_PAYSTACK_SIGNATURE='invalid',
        )
        assert response.status_code == 400
        assert response.json()['error']['code'] == 'WEBHOOK_SIGNATURE_INVALID'

    def test_webhook_idempotency_already_captured(self, api_client, captured_payment):
        """Replaying a webhook for an already-captured payment is safe."""
        payload = {
            'event': 'charge.success',
            'data': {
                'reference': captured_payment.provider_reference,
                'amount': captured_payment.amount,
            }
        }
        sig = self._sign(payload)
        response = api_client.post(
            '/api/v1/payments/webhooks/paystack',
            payload,
            content_type='application/json',
            HTTP_X_PAYSTACK_SIGNATURE=sig,
        )
        assert response.status_code == 200
        # confirm_appointment NOT called again
        captured_payment.refresh_from_db()
        assert captured_payment.status == 'captured'  # Unchanged
```

### Slot Generation Tests

```python
# slots/tests/test_slot_generation.py

class TestSlotGeneration:

    def test_generate_slots_from_template(self, db):
        template = AvailabilityTemplateFactory(
            day_of_week='monday',
            start_time=time(9, 0),
            end_time=time(12, 0),
            slot_duration_minutes=30,
        )
        with freeze_time('2025-06-09'):  # A Monday
            generate_slots_for_template(template.id)

        slots = Slot.objects.filter(doctor_profile=template.doctor_profile)
        # 3 hours / 30 min = 6 slots per Monday × 8 Mondays in 60 days
        assert slots.count() == 48

    def test_generate_slots_is_idempotent(self, db):
        template = AvailabilityTemplateFactory(day_of_week='tuesday')
        generate_slots_for_template(template.id)
        count_first = Slot.objects.filter(doctor_profile=template.doctor_profile).count()
        generate_slots_for_template(template.id)  # Run again
        count_second = Slot.objects.filter(doctor_profile=template.doctor_profile).count()
        assert count_first == count_second  # No duplicates

    def test_reservation_expiry_task_returns_slot_to_available(self, db):
        slot = SlotFactory(status='reserved')
        appt = AppointmentFactory(slot=slot, status='requested')
        slot.reservation_expires_at = timezone.now() - timedelta(minutes=1)
        slot.save()

        expire_slot_reservations()

        slot.refresh_from_db()
        appt.refresh_from_db()
        assert slot.status == 'available'
        assert appt.status == 'cancelled_by_platform'

    def test_unexpired_reservation_not_affected(self, db):
        slot = SlotFactory(status='reserved')
        slot.reservation_expires_at = timezone.now() + timedelta(minutes=5)
        slot.save()

        expire_slot_reservations()

        slot.refresh_from_db()
        assert slot.status == 'reserved'  # Unchanged
```

### Health Timeline Encryption Tests

```python
# health_records/tests/test_encryption.py

class TestHealthTimelineEncryption:

    def test_content_is_encrypted_at_rest(self, db):
        entry = HealthTimelineEntryFactory(
            content={'diagnosis': 'Acute pharyngitis', 'summary': 'Sore throat'}
        )
        # Raw DB value should be bytes, not readable JSON
        raw = HealthTimelineEntry.objects.filter(id=entry.id).values('content_encrypted').first()
        assert isinstance(raw['content_encrypted'], (bytes, memoryview))
        with pytest.raises(Exception):
            json.loads(raw['content_encrypted'])  # Should not be parseable as JSON

    def test_content_decrypts_correctly_on_read(self, db):
        original = {'diagnosis': 'Migraine', 'icd10_codes': ['G43.909']}
        entry = HealthTimelineEntryFactory(content=original)
        fetched = HealthTimelineEntry.objects.get(id=entry.id)
        assert fetched.content == original

    def test_different_entries_have_different_ivs(self, db):
        e1 = HealthTimelineEntryFactory(content={'note': 'a'})
        e2 = HealthTimelineEntryFactory(content={'note': 'b'})
        raw1 = HealthTimelineEntry.objects.filter(id=e1.id).values('content_iv').first()
        raw2 = HealthTimelineEntry.objects.filter(id=e2.id).values('content_iv').first()
        assert raw1['content_iv'] != raw2['content_iv']  # Unique IV per entry

    def test_per_patient_keys_differ(self, db):
        """Two patients, same plaintext — ciphertext must differ because
        the derived keys differ (different patient_key_salt)."""
        p1 = PatientProfileFactory()
        p2 = PatientProfileFactory()
        assert p1.patient_key_salt != p2.patient_key_salt
        payload = {'note': 'same content'}
        e1 = HealthTimelineEntryFactory(patient_id=p1.user_id, content=payload)
        e2 = HealthTimelineEntryFactory(patient_id=p2.user_id, content=payload)
        raw1 = HealthTimelineEntry.objects.filter(id=e1.id).values('content_encrypted').first()
        raw2 = HealthTimelineEntry.objects.filter(id=e2.id).values('content_encrypted').first()
        assert raw1['content_encrypted'] != raw2['content_encrypted']
```

---

### Supabase Direct-Read RLS Tests

Flutter and Next.js read a defined subset of tables directly via the Supabase client (bypassing Django). For every table in that subset, RLS is the *only* authorisation layer, so we test each directly against the database using a non-service JWT.

**Tables read directly by Flutter/Next.js (authoritative list — keep in sync with `clients/flutter/lib/data/supabase_reads.dart`):**

| Table / View             | Reader role(s)       | RLS policy to verify                                               |
| ------------------------ | -------------------- | ------------------------------------------------------------------ |
| `slots`                  | anon + authenticated | Only `status='available'` and `slot_date >= CURRENT_DATE` visible  |
| `doctor_profiles`        | anon + authenticated | Only `verification_status='verified' AND is_profile_active`        |
| `clinic_affiliations`    | anon + authenticated | Only rows whose doctor_profile is public                           |
| `reviews`                | anon + authenticated | Only `status='published' AND deleted_at IS NULL`                   |
| `v_appointments_safe`    | authenticated        | Only rows where user is patient or doctor; URLs null outside T-15  |
| `consent_grants`         | authenticated        | Only patient (own) or doctor (granted_to)                          |
| `saved_doctors`          | authenticated        | Only own                                                           |
| `notification_preferences` | authenticated      | Only own                                                           |

```python
# health_records/tests/test_rls_direct_read.py
import pytest
from supabase import create_client

@pytest.fixture
def supabase_as(user_factory):
    """Returns a Supabase client authenticated as a given user (JWT from Django)."""
    def _factory(user):
        client = create_client(settings.SUPABASE_URL, settings.SUPABASE_ANON_KEY)
        client.auth.set_session(access_token=mint_jwt(user), refresh_token='')
        return client
    return _factory


class TestTelehealthURLGate:
    def test_url_hidden_before_t_minus_15(self, supabase_as, appointment_factory):
        appt = appointment_factory(
            booking_mode='telehealth',
            slot__slot_date=tomorrow(),
            slot__start_time='10:00',
            telehealth_patient_url='https://daily.co/abc?token=xyz',
        )
        sb = supabase_as(appt.patient)
        row = sb.table('v_appointments_safe').select('*').eq('id', appt.id).single().execute()
        assert row.data['telehealth_patient_url'] is None

    def test_url_visible_within_t_minus_15(self, supabase_as, appointment_factory):
        appt = appointment_factory(
            booking_mode='telehealth',
            slot__slot_date=today(),
            slot__start_time=(now() + timedelta(minutes=10)).time(),
            telehealth_patient_url='https://daily.co/abc?token=xyz',
        )
        sb = supabase_as(appt.patient)
        row = sb.table('v_appointments_safe').select('*').eq('id', appt.id).single().execute()
        assert row.data['telehealth_patient_url'] == 'https://daily.co/abc?token=xyz'

    def test_raw_appointments_table_not_selectable_by_authenticated(self, supabase_as, user_factory):
        sb = supabase_as(user_factory(role='patient'))
        with pytest.raises(Exception):  # permission denied expected
            sb.table('appointments').select('telehealth_room_url').execute()


class TestTimelineNotDirectlyReadable:
    """ADR-0003: health_timeline_entries is Django-only. Content is encrypted with a
    per-patient key only Django holds, so a direct Supabase read is undecryptable AND
    widens the PHI surface. Direct SELECT is REVOKEd from `authenticated`. The direct-read
    suite therefore only asserts the table is unreachable from a client token; the actual
    patient/doctor timeline access (with decryption + consent enforcement) is tested at the
    DRF layer in health_records/tests/test_timeline.py and test_consent.py."""

    def test_authenticated_cannot_direct_read_timeline(self, supabase_as, timeline_entry_factory):
        entry = timeline_entry_factory()
        sb = supabase_as(entry.patient)          # even the owning patient
        with pytest.raises(Exception):            # permission denied — table SELECT revoked
            sb.table('health_timeline_entries').select('id').eq('id', entry.id).execute()

    # Consent enforcement for doctor timeline reads (with/without/revoked consent, plus
    # decryption) moved to the DRF layer — see health_records/tests/test_consent.py and
    # test_timeline.py — because the table is Django-only under ADR-0003. The RLS
    # `timeline_doctor_consent_read` policy still exists as defence in depth for the
    # service-role path and is exercised there.


class TestRealtimeRLS:
    """ADR-0003: appointments are NOT exposed via Realtime — base-table SELECT is revoked
    from `authenticated`, and Realtime Postgres Changes is table-level (cannot watch
    v_appointments_safe). Status changes ride on FCM push + pull. These tests lock in that
    decision: (1) an authenticated client receives NO appointment Realtime events, not even
    for its OWN appointment; (2) the one path we DO use — slots Realtime — respects the
    public RLS filter."""

    def test_appointments_realtime_delivers_nothing_to_authenticated(self, supabase_as, appointment_factory):
        appt = appointment_factory()                      # the subscriber's own appointment
        sb = supabase_as(appt.patient)
        received = []
        sb.channel('appointments').on('postgres_changes',
            event='*', schema='public', table='appointments',
            callback=lambda p: received.append(p)).subscribe()
        appointment_factory(patient=appt.patient)         # trigger an INSERT on the subscribed table
        time.sleep(2)
        assert received == []  # SELECT revoked → Realtime yields nothing; clients must use push+pull

    def test_slots_realtime_only_streams_available_future_slots(self, supabase_as, slot_factory, user_factory):
        sb = supabase_as(user_factory(role='patient'))
        received = []
        sb.channel('slots').on('postgres_changes',
            event='*', schema='public', table='slots',
            callback=lambda p: received.append(p)).subscribe()
        blocked = slot_factory(status='blocked')          # not in the public RLS set
        available = slot_factory(status='available')      # in the public RLS set
        time.sleep(2)
        ids = [p['new']['id'] for p in received]
        assert available.id in ids and blocked.id not in ids
```

**Coverage gate:** 100% of the tables in the direct-read list above must have at least one positive and one negative RLS test. CI fails if any table in the list has no corresponding test.

---

## Flutter Testing

### Test Stack

| Tool                          | Purpose                                                           |
| ----------------------------- | ----------------------------------------------------------------- |
| `flutter_test`                | Built-in test framework                                           |
| `mocktail`                    | Mock generation (preferred over `mockito` — no code gen required) |
| `bloc_test` / `riverpod_test` | Provider/notifier state testing                                   |
| `golden_toolkit`              | Screenshot regression tests                                       |
| `patrol`                      | E2E integration tests on device/emulator                          |
| `drift_test`                  | In-memory Drift database for unit tests                           |
| `fake_async`                  | Control async timers in unit tests                                |

### Project Test Structure

```
mobile/
├── test/
│   ├── helpers/
│   │   ├── mock_factories.dart        # Mocktail mocks for all repositories
│   │   ├── test_data.dart             # Shared test data objects
│   │   └── pump_app.dart              # Widget test helper (wraps app theme/providers)
│   ├── unit/
│   │   ├── use_cases/
│   │   │   ├── book_appointment_test.dart
│   │   │   ├── search_doctors_test.dart
│   │   │   └── get_timeline_test.dart
│   │   ├── repositories/
│   │   │   ├── appointment_repository_test.dart
│   │   │   └── doctor_repository_test.dart
│   │   ├── sync/
│   │   │   ├── conflict_resolver_test.dart
│   │   │   ├── sync_engine_test.dart
│   │   │   └── offline_queue_test.dart
│   │   └── forms/
│   │       ├── condition_evaluator_test.dart
│   │       └── form_validator_test.dart
│   ├── widget/
│   │   ├── screens/
│   │   │   ├── doctor_search_screen_test.dart
│   │   │   ├── booking_flow_test.dart
│   │   │   ├── appointment_detail_test.dart
│   │   │   └── health_timeline_test.dart
│   │   ├── components/
│   │   │   ├── slot_picker_test.dart
│   │   │   ├── pre_consultation_form_test.dart
│   │   │   └── appointment_card_test.dart
│   │   └── goldens/                   # Screenshot regression baselines
│   │       ├── doctor_card_light.png
│   │       ├── doctor_card_dark.png
│   │       ├── appointment_confirmed_light.png
│   │       └── ...
│   └── integration/
│       ├── booking_journey_test.dart
│       ├── offline_booking_test.dart
│       └── health_timeline_test.dart
```

### Unit Tests — Conflict Resolver

```dart
// test/unit/sync/conflict_resolver_test.dart

void main() {
  group('ConflictResolver', () {
    late MockAppointmentRepository mockRepo;
    late MockApiClient mockApi;
    late MockNotifier mockNotifier;
    late ConflictResolver resolver;

    setUp(() {
      mockRepo = MockAppointmentRepository();
      mockApi = MockApiClient();
      mockNotifier = MockNotifier();
      resolver = ConflictResolver(mockRepo, mockApi, mockNotifier);
    });

    group('CONFLICT-1: slot taken', () {
      test('deletes optimistic appointment and shows alternatives', () async {
        final op = OfflineOperation(
          id: 'test-op-uuid',
          type: OperationType.createAppointment,
          payload: jsonEncode({
            'doctor_profile_id': 'doctor-uuid',
            'slot_id': 'slot-uuid',
            'slot_date': '2025-06-15',
          }),
          priority: OperationPriority.critical,
          linkedLocalId: 42,
        );
        final error = ConflictException(code: 'SLOT_UNAVAILABLE');
        final alternatives = [SlotModel.fixture()];

        when(() => mockApi.doctors.getSlots(any(), any(), any()))
            .thenAnswer((_) async => alternatives);
        when(() => mockRepo.deleteByLocalId(42))
            .thenAnswer((_) async {});

        await resolver.handleSlotUnavailable(op, error);

        verify(() => mockRepo.deleteByLocalId(42)).called(1);
        verify(() => mockNotifier.showConflict(any(
          that: isA<ConflictNotification>()
            .having((n) => n.type, 'type', ConflictType.slotTaken)
            .having((n) => n.alternativeSlots, 'alternatives', alternatives),
        ))).called(1);
      });

      test('preserves form responses in BookingRecoveryCache', () async {
        final responses = {'field-001': 'Headache for 3 days'};
        BookingRecoveryCache.store('doctor-uuid', responses);

        expect(BookingRecoveryCache.retrieve('doctor-uuid'), equals(responses));
      });
    });

    group('CONFLICT-2: appointment already terminal', () {
      test('syncs server state and shows informational message', () async {
        final serverAppt = AppointmentModel.fixture(
          status: AppointmentStatus.cancelledByDoctor,
        );
        when(() => mockApi.appointments.get(any()))
            .thenAnswer((_) async => serverAppt);
        when(() => mockRepo.upsert(any())).thenAnswer((_) async {});

        final op = OfflineOperation(
          type: OperationType.cancelAppointment,
          payload: jsonEncode({'appointment_id': 'appt-uuid'}),
          priority: OperationPriority.critical,
        );

        await resolver.handleAlreadyTerminal(op, ConflictException(code: 'APPOINTMENT_ALREADY_TERMINAL'));

        verify(() => mockRepo.upsert(serverAppt)).called(1);
        verify(() => mockNotifier.showInfo(any(
          that: isA<InfoNotification>()
            .having((n) => n.title, 'title', contains('already cancelled')),
        ))).called(1);
      });
    });

    group('CONFLICT-9: payment booking offline prevention', () {
      test('returns requiresConnectivity for payment bookings when offline', () async {
        final connectivity = MockConnectivityMonitor();
        when(() => connectivity.state).thenReturn(ConnectivityState.offline);
        final bookingService = BookingService(connectivity, mockApi, mockRepo);

        final result = await bookingService.createBooking(
          CreateAppointmentRequest(requiresPayment: true, slotId: 'slot-uuid'),
        );

        expect(result, isA<BookingResult>());
        expect(result.requiresConnectivity, isTrue);
      });

      test('allows pay-at-desk booking to be queued offline', () async {
        final connectivity = MockConnectivityMonitor();
        when(() => connectivity.state).thenReturn(ConnectivityState.offline);
        final bookingService = BookingService(connectivity, mockApi, mockRepo);

        final result = await bookingService.createBooking(
          CreateAppointmentRequest(requiresPayment: false, slotId: 'slot-uuid'),
        );

        expect(result.wasQueued, isTrue);
      });
    });
  });
}
```

### Unit Tests — Form Condition Evaluator

```dart
// test/unit/forms/condition_evaluator_test.dart

void main() {
  group('ConditionEvaluator', () {
    final evaluator = ConditionEvaluator();

    test('equals operator - boolean true', () {
      final condition = FieldCondition(
        fieldId: 'field-a',
        operator: ConditionOperator.equals,
        value: true,
      );
      expect(evaluator.evaluate(condition, {'field-a': true}, {'field-a'}), isTrue);
      expect(evaluator.evaluate(condition, {'field-a': false}, {'field-a'}), isFalse);
    });

    test('contains operator - multi_select includes value', () {
      final condition = FieldCondition(
        fieldId: 'symptoms',
        operator: ConditionOperator.contains,
        value: 'chest_pain',
      );
      final responses = {'symptoms': ['cough', 'chest_pain', 'fever']};
      expect(evaluator.evaluate(condition, responses, {'symptoms'}), isTrue);
    });

    test('hidden referenced field causes dependent to be hidden', () {
      // Field B depends on Field A, but Field A is itself hidden
      final condition = FieldCondition(fieldId: 'field-a', operator: ConditionOperator.equals, value: true);
      final visibleFields = <String>{}; // field-a is NOT in visible set
      expect(evaluator.evaluate(condition, {'field-a': true}, visibleFields), isFalse);
    });

    test('AND compound condition - both must be true', () {
      final condition = FieldCondition(
        fieldId: 'is_pregnant',
        operator: ConditionOperator.equals,
        value: true,
        and: FieldCondition(
          fieldId: 'trimester',
          operator: ConditionOperator.equals,
          value: 'first',
        ),
      );
      final responses = {'is_pregnant': true, 'trimester': 'first'};
      final visible = {'is_pregnant', 'trimester'};
      expect(evaluator.evaluate(condition, responses, visible), isTrue);

      final responses2 = {'is_pregnant': true, 'trimester': 'second'};
      expect(evaluator.evaluate(condition, responses2, visible), isFalse);
    });

    test('clearing hidden field values', () {
      final fields = [
        BooleanField(id: 'has_condition', order: 10, label: 'Chronic condition?', required: true),
        TextField(
          id: 'condition_name', order: 20, label: 'Which condition?', required: true,
          condition: FieldCondition(fieldId: 'has_condition', operator: ConditionOperator.equals, value: true),
        ),
      ];
      // Patient answered condition_name but has_condition is false
      final responses = {'has_condition': false, 'condition_name': 'Diabetes'};
      final cleaned = FormResponseCleaner.clean(fields, responses);
      expect(cleaned.containsKey('condition_name'), isFalse); // Cleared
      expect(cleaned.containsKey('has_condition'), isTrue);
    });
  });
}
```

### Widget Tests

```dart
// test/widget/screens/booking_flow_test.dart

void main() {
  group('BookingFlowScreen', () {
    testWidgets('shows slot picker on step 1', (tester) async {
      await tester.pumpApp(
        BookingFlowScreen(doctorId: 'test-doctor-uuid'),
        overrides: [
          slotsProvider.overrideWith((_) => AsyncValue.data(mockSlots)),
        ],
      );
      expect(find.byType(SlotPickerWidget), findsOneWidget);
      expect(find.text('Select a time'), findsOneWidget);
    });

    testWidgets('advances to pre-consultation form after slot selection', (tester) async {
      await tester.pumpApp(BookingFlowScreen(doctorId: 'test-doctor-uuid'));
      await tester.tap(find.byKey(const Key('slot-9:00-AM')));
      await tester.pumpAndSettle();
      expect(find.byType(PreConsultationFormRenderer), findsOneWidget);
    });

    testWidgets('shows connectivity warning when offline and payment required', (tester) async {
      await tester.pumpApp(
        BookingFlowScreen(doctorId: 'test-doctor-uuid'),
        overrides: [
          connectivityProvider.overrideWith((_) => ConnectivityState.offline),
          slotProvider.overrideWith((_) => AsyncValue.data(paymentRequiredSlot)),
        ],
      );
      // Navigate to payment step
      await tester.tap(find.text('Continue to payment'));
      await tester.pumpAndSettle();
      expect(find.text('Connect to the internet to complete your booking'), findsOneWidget);
      expect(find.byKey(const Key('confirm-booking-button')), findsNothing);
    });

    testWidgets('pre-consultation conditional fields appear and disappear', (tester) async {
      await tester.pumpApp(PreConsultationFormRenderer(
        fields: formFieldsWithCondition,
        onSubmit: (_) {},
      ));

      // 'Which condition?' should be hidden initially
      expect(find.text('Which condition?'), findsNothing);

      // Tap 'Yes' on 'Do you have a chronic condition?'
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();

      // Now it should appear
      expect(find.text('Which condition?'), findsOneWidget);

      // Tap 'No' — it should disappear again
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      expect(find.text('Which condition?'), findsNothing);
    });
  });
}
```

### Golden Tests (Screenshot Regression)

```dart
// test/widget/goldens/doctor_card_golden_test.dart

void main() {
  testGoldens('DoctorCard - light theme', (tester) async {
    await tester.pumpWidgetBuilder(
      DoctorCard(doctor: mockDoctorSummary),
      wrapper: materialAppWrapper(theme: VeridianTheme.light),
    );
    await screenMatchesGolden(tester, 'doctor_card_light');
  });

  testGoldens('DoctorCard - dark theme', (tester) async {
    await tester.pumpWidgetBuilder(
      DoctorCard(doctor: mockDoctorSummary),
      wrapper: materialAppWrapper(theme: VeridianTheme.dark),
    );
    await screenMatchesGolden(tester, 'doctor_card_dark');
  });

  testGoldens('AppointmentCard - confirmed state', (tester) async {
    await tester.pumpWidgetBuilder(
      AppointmentCard(appointment: confirmedAppointment),
    );
    await screenMatchesGolden(tester, 'appointment_card_confirmed');
  });

  testGoldens('AppointmentCard - pending sync badge', (tester) async {
    await tester.pumpWidgetBuilder(
      AppointmentCard(appointment: pendingSyncAppointment),
    );
    await screenMatchesGolden(tester, 'appointment_card_pending_sync');
  });
}
```

---

## Next.js Testing

### Test Stack

| Tool                        | Purpose                                                            |
| --------------------------- | ------------------------------------------------------------------ |
| `vitest`                    | Unit and component test runner (faster than Jest for Vite/Next.js) |
| `@testing-library/react`    | Component rendering and interaction                                |
| `msw` (Mock Service Worker) | API mocking at the network level                                   |
| `Playwright`                | E2E browser testing                                                |
| `@axe-core/playwright`      | Accessibility testing within E2E                                   |

### Project Test Structure

```
web/
├── __tests__/
│   ├── unit/
│   │   ├── lib/
│   │   │   ├── money.test.ts          # MoneyAmount formatting utilities
│   │   │   ├── dates.test.ts          # Timezone conversion utilities
│   │   │   └── form-conditions.test.ts # Condition evaluator (mirrors Flutter logic)
│   │   └── hooks/
│   │       ├── useSlots.test.ts
│   │       └── useBooking.test.ts
│   ├── components/
│   │   ├── DoctorCard.test.tsx
│   │   ├── PreConsultationForm.test.tsx
│   │   ├── SlotPicker.test.tsx
│   │   └── AppointmentStatusBadge.test.tsx
│   └── pages/
│       ├── DoctorSearchPage.test.tsx
│       └── BookingPage.test.tsx
└── e2e/
    ├── booking-journey.spec.ts        # Full booking funnel
    ├── doctor-search.spec.ts
    ├── health-timeline.spec.ts
    └── auth.spec.ts
```

### Component Tests

```typescript
// __tests__/components/PreConsultationForm.test.tsx

describe('PreConsultationForm', () => {
  const mockFields = [
    {
      id: 'field-001',
      type: 'boolean' as const,
      label: 'Do you have a chronic condition?',
      required: true,
      order: 10,
    },
    {
      id: 'field-002',
      type: 'text' as const,
      label: 'Which condition?',
      required: true,
      order: 20,
      condition: {
        field_id: 'field-001',
        operator: 'equals' as const,
        value: true,
      },
    },
  ];

  it('hides conditional field initially', () => {
    render(<PreConsultationForm fields={mockFields} onSubmit={vi.fn()} />);
    expect(screen.queryByText('Which condition?')).not.toBeInTheDocument();
  });

  it('shows conditional field when condition is met', async () => {
    render(<PreConsultationForm fields={mockFields} onSubmit={vi.fn()} />);
    await userEvent.click(screen.getByLabelText('Yes'));
    expect(screen.getByText('Which condition?')).toBeInTheDocument();
  });

  it('clears conditional field answer when hidden', async () => {
    const onSubmit = vi.fn();
    render(<PreConsultationForm fields={mockFields} onSubmit={onSubmit} />);

    await userEvent.click(screen.getByLabelText('Yes'));
    await userEvent.type(screen.getByLabelText('Which condition?'), 'Diabetes');
    await userEvent.click(screen.getByLabelText('No'));

    await userEvent.click(screen.getByRole('button', { name: /continue/i }));
    expect(onSubmit).toHaveBeenCalledWith(
      expect.not.objectContaining({ 'field-002': expect.anything() })
    );
  });

  it('blocks submission when required visible field is empty', async () => {
    const onSubmit = vi.fn();
    render(<PreConsultationForm fields={mockFields} onSubmit={onSubmit} />);
    await userEvent.click(screen.getByRole('button', { name: /continue/i }));
    expect(onSubmit).not.toHaveBeenCalled();
    expect(screen.getByText('Please answer yes or no.')).toBeInTheDocument();
  });
});
```

### E2E Tests — Booking Journey

```typescript
// e2e/booking-journey.spec.ts

test.describe("Booking journey — happy path", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await loginAsPatient(page); // Helper: fills login form, handles OTP mock
  });

  test("patient completes full booking flow", async ({ page }) => {
    // Step 1: Search
    await page.goto("/doctors");
    await page
      .getByPlaceholder("Search doctors, specializations...")
      .fill("cardiologist Accra");
    await page.waitForSelector('[data-testid="doctor-card"]');
    await page.getByTestId("doctor-card").first().click();

    // Step 2: Doctor profile
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    await page.getByRole("button", { name: /book appointment/i }).click();

    // Step 3: Slot selection
    await expect(page.getByTestId("slot-picker")).toBeVisible();
    await page.getByTestId("slot-09:00").click();
    await page.getByRole("button", { name: /continue/i }).click();

    // Step 4: Pre-consultation form
    await expect(page.getByText("What is your main reason")).toBeVisible();
    await page
      .getByRole("textbox", { name: /reason/i })
      .fill("Routine checkup");
    await page.getByLabel("Less than 24 hours").click();
    await page.getByLabel("No").nth(0).click(); // Not a follow-up
    await page.getByLabel("No").nth(1).click(); // No medications
    await page.getByLabel("No").nth(2).click(); // No allergies
    await page.getByRole("button", { name: /continue/i }).click();

    // Step 5: Review
    await expect(page.getByText("Review your booking")).toBeVisible();
    await expect(page.getByText("GHS 150.00")).toBeVisible();
    await page.getByRole("button", { name: /confirm and pay/i }).click();

    // Step 6: Payment (mocked via MSW — returns mock Paystack response)
    await expect(page.getByText("Booking confirmed")).toBeVisible();
    await expect(page.getByTestId("appointment-card")).toBeVisible();
  });

  test("shows slot unavailable error when slot taken", async ({ page }) => {
    // MSW intercepts POST /appointments and returns 409
    await page.route("**/api/v1/appointments", (route) =>
      route.fulfill({
        status: 409,
        body: JSON.stringify({
          error: {
            code: "SLOT_UNAVAILABLE",
            message: "Slot is no longer available.",
          },
        }),
      }),
    );
    await selectSlotAndSubmitForm(page);
    await expect(page.getByText("That slot was just taken")).toBeVisible();
    await expect(page.getByText("See available slots")).toBeVisible();
  });
});

test.describe("Accessibility", () => {
  test("booking flow has no critical accessibility violations", async ({
    page,
  }) => {
    const { checkA11y } = await import("@axe-core/playwright");
    await page.goto("/doctors");
    await checkA11y(page, null, {
      runOnly: { type: "tag", values: ["wcag2a", "wcag2aa"] },
    });
  });
});
```

---

## CI/CD Pipeline Gates

### GitHub Actions Workflow

```yaml
# .github/workflows/ci.yml

name: CI

on: [push, pull_request]

jobs:
  django:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: supabase/postgres:15
        env:
          POSTGRES_PASSWORD: test
        ports: ["5432:5432"]
      redis:
        image: redis:7
        ports: ["6379:6379"]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: pip install -r requirements/test.txt
      - name: Run linting
        run: ruff check . && ruff format --check .
      - name: Run type checking
        run: mypy apps/
      - name: Run tests with coverage
        run: |
          pytest --cov=apps --cov-report=xml \
                 --cov-fail-under=90 \
                 -x --tb=short
        env:
          DATABASE_URL: postgresql://postgres:test@localhost/Veridian_test
          REDIS_URL: redis://localhost:6379/0
          SECRET_KEY: test-secret-key
          PAYSTACK_SECRET_KEY: test-key
      - name: Upload coverage
        uses: codecov/codecov-action@v4

  flutter:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: { flutter-version: "3.24.x", channel: "stable" }
      - run: flutter pub get
      - name: Analyze
        run: flutter analyze
      - name: Run unit and widget tests with coverage
        run: |
          flutter test --coverage \
                       test/unit/ test/widget/ \
                       --coverage-path coverage/lcov.info
      - name: Check coverage threshold
        run: |
          lcov --summary coverage/lcov.info | \
          awk '/lines/ { if ($2+0 < 85) { print "Coverage below 85%"; exit 1 } }'
      - name: Verify goldens up to date
        run: flutter test test/widget/goldens/ --update-goldens --dry-run

  nextjs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20" }
      - run: npm ci
      - name: Lint
        run: npm run lint
      - name: Type check
        run: npm run type-check
      - name: Unit and component tests
        run: npm run test:coverage -- --reporter=verbose
      - name: Check coverage
        run: |
          node -e "
            const r = require('./coverage/coverage-summary.json');
            const pct = r.total.lines.pct;
            if (pct < 80) { console.error('Coverage', pct, '< 80%'); process.exit(1); }
          "

  e2e:
    runs-on: ubuntu-latest
    needs: [django, nextjs] # Only run E2E if unit tests pass
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20" }
      - run: npm ci
      - run: npx playwright install --with-deps chromium
      - name: Start test server
        run: npm run dev &
        env: { NODE_ENV: test }
      - name: Wait for server
        run: npx wait-on http://localhost:3000
      - name: Run E2E tests
        run: npx playwright test --reporter=html
      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: playwright-report
          path: playwright-report/
```

### Non-Negotiable CI Gates

The following checks must pass before any PR is merged and before any production deployment:

| Gate                                 | Tool                      | Threshold                   | Blocks merge?        |
| ------------------------------------ | ------------------------- | --------------------------- | -------------------- |
| Django linting                       | `ruff`                    | Zero violations             | Yes                  |
| Django type checking                 | `mypy`                    | Zero errors                 | Yes                  |
| Django test coverage                 | `pytest-cov`              | ≥ 90% lines                 | Yes                  |
| Django critical path branch coverage | `pytest-cov --branch`     | 100% on critical paths      | Yes                  |
| Flutter analysis                     | `flutter analyze`         | Zero errors, zero warnings  | Yes                  |
| Flutter test coverage                | `lcov`                    | ≥ 85% lines                 | Yes                  |
| Flutter golden tests                 | `golden_toolkit`          | Zero regressions            | Yes                  |
| Next.js linting                      | `eslint`                  | Zero errors                 | Yes                  |
| Next.js type checking                | `tsc`                     | Zero errors                 | Yes                  |
| Next.js test coverage                | `vitest --coverage`       | ≥ 80% lines                 | Yes                  |
| E2E booking journey                  | `playwright`              | All scenarios pass          | Yes (staging deploy) |
| E2E accessibility                    | `axe-core`                | Zero WCAG 2.1 AA violations | Yes (staging deploy) |
| Security headers check               | `securityheaders.com` API | Grade A or above            | Yes (staging deploy) |

---

## Test Data Strategy

### Principles

1. **No real data.** All test data is synthetic. Factories use Faker with Ghanaian locale (`en_GH`) for realistic-looking but fake names, phone numbers, and addresses.

2. **Isolated per test.** Django tests use `pytest-django`'s `db` fixture which wraps each test in a transaction that is rolled back after the test. No test pollutes another's data.

3. **Deterministic seeds.** Tests that require "random" data (e.g. UUIDs) use seeded randomness where the seed is derived from the test name. This makes failures reproducible.

4. **Fixture minimalism.** Tests create only what they need. A test for appointment cancellation creates a doctor, a slot, and an appointment — not a full platform state.

5. **No external services in CI.** All external API calls (Paystack, Termii, Daily.co, OpenAI, Supabase Storage) are mocked:
   - Django: `responses` library intercepts `requests` calls
   - Flutter: `mocktail` mocks all repository interfaces
   - Next.js: `msw` intercepts `fetch` at the network level
   - E2E: `msw` in the browser context + a local test API server

### Sensitive Field Handling in Tests

```python
# factories.py — sensitive fields use obviously fake values

class HealthTimelineEntryFactory(DjangoModelFactory):
    # Content uses obviously synthetic data
    content = factory.LazyAttribute(lambda _: {
        'diagnosis': 'TEST_DIAGNOSIS_DO_NOT_USE',
        'summary': 'Test entry — not real patient data',
        'icd10_codes': ['Z00.00'],  # Routine examination — no real condition
    })

class PaymentTransactionFactory(DjangoModelFactory):
    provider_reference = factory.LazyAttribute(
        lambda _: f'TEST_{uuid.uuid4().hex[:8].upper()}'
    )
    amount = 15000  # GHS 150.00
    currency_code = 'GHS'
```

---

## Performance Testing

Performance tests run in the staging environment against a pre-seeded dataset of realistic scale. They do not run on every CI push — they run weekly and before major releases.

### Load Profile (Realistic Peak — Ghana market)

| Scenario                                   | Concurrent users     | Duration | Ramp-up |
| ------------------------------------------ | -------------------- | -------- | ------- |
| Doctor search + browse                     | 500                  | 10 min   | 2 min   |
| Simultaneous bookings                      | 100                  | 5 min    | 1 min   |
| Slot availability poll (Supabase Realtime) | 1,000 connections    | 5 min    | 30 sec  |
| Webhook processing (Paystack)              | 200 events/sec burst | 60 sec   | N/A     |

### Performance Targets (must pass before release)

| Endpoint                           | p50     | p95     | p99     | Error rate |
| ---------------------------------- | ------- | ------- | ------- | ---------- |
| `GET /doctors` (SQL only)          | < 80ms  | < 200ms | < 400ms | < 0.1%     |
| `GET /doctors` (semantic search)   | < 200ms | < 500ms | < 800ms | < 0.1%     |
| `GET /doctors/{id}/slots`          | < 60ms  | < 150ms | < 300ms | < 0.1%     |
| `POST /appointments`               | < 200ms | < 400ms | < 600ms | < 0.5%     |
| `POST /payments/webhooks/paystack` | < 50ms  | < 100ms | < 200ms | < 0.01%    |
| `GET /patients/me/timeline`        | < 100ms | < 250ms | < 500ms | < 0.1%     |
| Flutter app cold start             | < 1.5s  | < 2.5s  | < 4s    | N/A        |
| Next.js LCP (4G throttled)         | < 1.2s  | < 2.0s  | < 3.0s  | N/A        |

### Tool

```bash
# k6 for API load testing
k6 run --vus 100 --duration 5m scripts/load/booking-load-test.js

# Playwright for web performance (Lighthouse CI)
npx lhci autorun --config=lighthouserc.js
```

---

## Pre-Production Deployment Checklist

Before every production deployment, the following must be confirmed by the deploying engineer:

```
□ All CI gates passing on the deploy branch
□ Django migrations reviewed (no destructive migration without a rollback plan)
□ New environment variables added to Railway (not just local .env)
□ Celery Beat tasks reviewed (new tasks added to the schedule)
□ Feature flags for new features set to 0% rollout (not enabled globally)
□ Performance test suite passing on staging with production-scale seed data
□ Security headers check passing (Grade A)
□ Changelog updated with all user-facing changes
□ On-call engineer notified of deployment window
□ Rollback procedure reviewed and tested in staging
□ Database backup confirmed (Supabase auto-backup + manual snapshot)
□ Sentry release created and source maps uploaded
```

---

\*Next document: **Document 8 of 10 — Operational Runbooks\***  
_Step-by-step response procedures for the top failure scenarios: double-booking, payment webhook failure, Celery task queue backup, database connection exhaustion, health record encryption key rotation, and more._

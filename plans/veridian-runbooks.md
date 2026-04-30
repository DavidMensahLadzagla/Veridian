# Veridian — Document 8 of 10: Operational Runbooks

**Project:** Veridian All-in-One Service Booking Platform  
**Version:** 1.0.0  
**Status:** Authoritative — all on-call response procedures derive from this document  
**Classification:** Internal — engineering and operations personnel only  
**Last reviewed:** See git history

---

## How to Use This Document

Each runbook follows a fixed structure:

- **Trigger** — what alerts or observations indicate this scenario
- **Severity** — P0 (business down), P1 (major degradation), P2 (partial degradation), P3 (minor)
- **Impact** — who is affected and how
- **Immediate actions** — what to do in the first 5 minutes (stop the bleeding)
- **Diagnosis steps** — how to confirm what is happening and why
- **Resolution steps** — how to fix it
- **Verification** — how to confirm it is fixed
- **Communication** — what to tell users and when
- **Post-mortem trigger** — whether a post-mortem is required

**Escalation path:**

- P0: Wake the on-call engineer immediately. Escalate to CTO within 15 minutes if not resolved.
- P1: Page on-call engineer. Escalate if not resolved in 30 minutes.
- P2: Notify on-call engineer via Slack. Resolve within 4 hours.
- P3: Create ticket. Resolve in next sprint.

---

## Runbook Index

| #     | Scenario                                         | Severity | Est. resolution time |
| ----- | ------------------------------------------------ | -------- | -------------------- |
| RB-01 | Double booking occurred                          | P1       | 30 min               |
| RB-02 | Paystack webhook silent failure                  | P1       | 45 min               |
| RB-03 | Celery task queue backup                         | P1       | 20 min               |
| RB-04 | Database connection exhaustion                   | P0       | 15 min               |
| RB-05 | Health record encryption key rotation            | P2       | 2 hours              |
| RB-06 | Slot generation task failure                     | P2       | 30 min               |
| RB-07 | Doctor no-show surge                             | P1       | 1 hour               |
| RB-08 | Payment refund stuck in pending                  | P2       | 45 min               |
| RB-09 | OTP delivery failure (Termii outage)             | P1       | 30 min               |
| RB-10 | Supabase Realtime disconnection at scale         | P2       | 20 min               |
| RB-11 | High memory / OOM on Django worker               | P1       | 20 min               |
| RB-12 | JWT signing key compromise                       | P0       | 1 hour               |
| RB-13 | Fake doctor profile discovered post-verification | P0       | 45 min               |
| RB-14 | Railway deployment failure / rollback            | P1       | 20 min               |
| RB-15 | Health data breach suspected                     | P0       | Immediate            |
| RB-16 | Quarterly backup restore drill                   | P2       | 2 hours (scheduled)  |
| RB-17 | Audit log chain verification & archive           | P0 (on alert) | 1 hour          |

---

## RB-01: Double Booking Occurred

**Trigger:**

- Alert fires from `appointment_monitoring`: two non-terminal appointments found with the same `slot_id`
- Patient or doctor reports seeing two patients at same time slot

**Severity:** P1  
**Impact:** Two patients expect to see the doctor at the same time. One will be turned away. Trust damage.

### Immediate Actions (< 5 minutes)

```bash
# 1. Identify the affected slot and both appointments
psql $DATABASE_URL << 'EOF'
SELECT
  a.id AS appointment_id,
  a.patient_id,
  a.status,
  a.created_at,
  u.full_name AS patient_name,
  u.phone
FROM appointments a
JOIN users u ON u.id = a.patient_id
WHERE a.slot_id = '<SLOT_ID_FROM_ALERT>'
  AND a.deleted_at IS NULL
  AND a.status NOT IN (
    'cancelled_by_patient','cancelled_by_doctor',
    'cancelled_by_platform','no_show_patient','no_show_doctor'
  )
ORDER BY a.created_at;
EOF

# 2. Note which appointment was created SECOND (the duplicate)
# 3. Check if slot.status is actually 'booked' (should only be booked once)
psql $DATABASE_URL -c "SELECT id, status, doctor_profile_id FROM slots WHERE id = '<SLOT_ID>';"
```

### Diagnosis Steps

```bash
# Confirm it is a genuine double-booking (not a reporting artifact)
psql $DATABASE_URL << 'EOF'
SELECT
  a.id,
  a.status,
  a.created_at,
  ast.from_status,
  ast.to_status,
  ast.created_at AS transition_at
FROM appointments a
JOIN appointment_status_history ast ON ast.appointment_id = a.id
WHERE a.slot_id = '<SLOT_ID>'
ORDER BY a.created_at, ast.created_at;
EOF

# Check audit log for the slot around the double-booking window
psql $DATABASE_URL << 'EOF'
SELECT *
FROM audit_log
WHERE table_name = 'slots'
  AND record_id = '<SLOT_ID>'
ORDER BY created_at DESC
LIMIT 20;
EOF

# Check payment_transactions for both appointments
psql $DATABASE_URL << 'EOF'
SELECT
  pt.id,
  pt.appointment_id,
  pt.status,
  pt.provider_reference,
  pt.amount,
  pt.captured_at
FROM payment_transactions pt
WHERE pt.appointment_id IN ('<APPT_ID_1>', '<APPT_ID_2>');
EOF
```

**Root cause categories:**

- A: `SELECT FOR UPDATE` not used (service layer bug)
- B: Two requests hit different DB replicas before replication sync (confirm Supabase read replica config)
- C: Unique constraint on `(doctor_profile_id, slot_date, start_time)` was absent or bypassed

### Resolution Steps

```bash
# Step 1: Determine which appointment is "legitimate"
# The first by created_at is typically legitimate.
# Check which patient was actually seen (call doctor if possible).

# Step 2: Cancel the duplicate appointment as platform
psql $DATABASE_URL << 'EOF'
BEGIN;
UPDATE appointments
SET
  status = 'cancelled_by_platform',
  cancelled_at = NOW(),
  cancellation_reason = 'Duplicate booking due to system error — full refund issued',
  cancelled_by = (SELECT id FROM users WHERE role = 'platform_admin' LIMIT 1)
WHERE id = '<DUPLICATE_APPOINTMENT_ID>';

INSERT INTO appointment_status_history
  (appointment_id, from_status, to_status, reason, created_at)
VALUES
  ('<DUPLICATE_APPOINTMENT_ID>', 'confirmed', 'cancelled_by_platform',
   'Double booking resolution', NOW());

UPDATE slots SET status = 'booked' WHERE id = '<SLOT_ID>';
COMMIT;
EOF

# Step 3: Trigger full refund for duplicate patient
# In Django shell:
python manage.py shell -c "
from payments.services import process_refund
from payments.models import PaymentTransaction
txn = PaymentTransaction.objects.get(appointment_id='<DUPLICATE_APPOINTMENT_ID>')
process_refund(txn.id, txn.amount, reason='Double booking — full refund')
"

# Step 4: Notify affected patient directly (SMS + email via admin panel)
python manage.py notify_patient \
  --patient-id <DUPLICATE_PATIENT_ID> \
  --template double_booking_apology \
  --include-priority-rebooking
```

### Verification

```bash
# Confirm only one non-terminal appointment for the slot
psql $DATABASE_URL -c "
SELECT COUNT(*) FROM appointments
WHERE slot_id = '<SLOT_ID>'
  AND status NOT IN ('cancelled_by_patient','cancelled_by_doctor',
                     'cancelled_by_platform','no_show_patient','no_show_doctor');
"
# Expected: 1

# Confirm refund initiated
psql $DATABASE_URL -c "
SELECT status, refunded_amount FROM payment_transactions
WHERE appointment_id = '<DUPLICATE_APPOINTMENT_ID>';
"
# Expected: status = 'refunded', refunded_amount = full amount
```

### Communication

- **Affected patient (duplicate):** SMS + email within 10 minutes: "We're very sorry — a system error caused a duplicate booking. Your appointment has been cancelled and a full refund has been processed (3–5 business days). We're offering you a priority slot — please tap here to rebook."
- **Affected patient (original):** No notification (their appointment is unaffected).
- **Doctor:** Brief notification that a duplicate was resolved.
- **Public:** No public communication unless media enquiry.

**Post-mortem:** Always required for a double-booking. Investigate root cause category A/B/C above within 48 hours.

---

## RB-02: Paystack Webhook Silent Failure

**Trigger:**

- Appointments stuck in `requested` status for > 15 minutes after expected payment completion
- Patient reports "I paid but my booking isn't confirmed"
- Paystack dashboard shows `charge.success` events not reflected in Veridian payment_transactions
- Alert: `payments_pending_over_15min` count > 5

**Severity:** P1  
**Impact:** Patients paid but appointments not confirmed. Slot may expire. Revenue at risk.

### Immediate Actions (< 5 minutes)

```bash
# 1. Check if webhook endpoint is reachable
curl -I https://api.Veridian.app/api/v1/payments/webhooks/paystack
# Expected: 200. If 5xx, Django is down — escalate to RB-11.

# 2. Check Paystack dashboard for failed webhook deliveries
# Go to: https://dashboard.paystack.com/ → Settings → Webhooks → Delivery logs
# Look for 5xx responses or timeouts in the last 30 minutes.

# 3. Identify stuck appointments
psql $DATABASE_URL << 'EOF'
SELECT
  a.id AS appointment_id,
  a.patient_id,
  a.status,
  a.created_at,
  pt.provider_reference,
  pt.status AS payment_status,
  pt.provider_response
FROM appointments a
JOIN payment_transactions pt ON pt.appointment_id = a.id
WHERE a.status = 'requested'
  AND pt.status = 'pending'
  AND a.created_at < NOW() - INTERVAL '15 minutes'
ORDER BY a.created_at;
EOF
```

### Diagnosis Steps

```bash
# Check Django webhook handler logs in Sentry/Railway
railway logs --service api --tail 100 | grep "paystack/webhook"

# Check if webhook HMAC validation is failing
# If Paystack rotated the secret key without notification:
railway logs | grep "WEBHOOK_SIGNATURE_INVALID"

# Check Celery task queue for stuck payment tasks
celery -A Veridian inspect active --destination celery@worker1
celery -A Veridian inspect reserved

# Verify Paystack transaction status directly via API (bypass webhooks)
python manage.py shell -c "
import requests
references = ['REF1', 'REF2']  # From stuck payment_transactions
for ref in references:
    r = requests.get(
        f'https://api.paystack.co/transaction/verify/{ref}',
        headers={'Authorization': 'Bearer \$PAYSTACK_SECRET_KEY'}
    )
    print(ref, r.json()['data']['status'], r.json()['data']['amount'])
"
```

### Resolution Steps

```bash
# OPTION A: Paystack webhook is down/failing — manually verify and confirm payments

python manage.py shell -c "
from payments.services import manually_verify_and_confirm
from payments.models import PaymentTransaction

stuck = PaymentTransaction.objects.filter(
    status='pending',
    appointment__status='requested',
    appointment__created_at__lt=timezone.now() - timedelta(minutes=15)
)
for txn in stuck:
    result = manually_verify_and_confirm(txn.id)
    print(f'Appointment {txn.appointment_id}: {result}')
"

# OPTION B: Webhook secret key mismatch — update Railway env var
# 1. Get current key from Paystack dashboard → Settings → API Keys
# 2. Update in Railway:
railway variables set PAYSTACK_SECRET_KEY=<new_key> --service api
railway redeploy --service api

# OPTION C: Celery worker is not processing payment tasks — restart worker
railway restart --service celery-worker

# OPTION D: All payments failed legitimately (Paystack-side failure)
# Check Paystack status page: https://status.paystack.com/
# If Paystack is down: release held slots, notify patients to rebook when restored
python manage.py release_expired_payment_reservations --dry-run
python manage.py release_expired_payment_reservations  # Run without dry-run after confirming
```

### Verification

```bash
psql $DATABASE_URL -c "
SELECT COUNT(*) FROM appointments a
JOIN payment_transactions pt ON pt.appointment_id = a.id
WHERE a.status = 'requested' AND pt.status = 'pending'
  AND a.created_at < NOW() - INTERVAL '15 minutes';
"
# Expected: 0 or rapidly decreasing
```

### Communication

- **Affected patients:** Push + SMS: "Your payment was received. Your booking is now confirmed." (triggered by the manual verify process)
- If Paystack is fully down: "We're experiencing a temporary payment issue. Your slot has been held for 1 hour. Please try again shortly."

**Post-mortem:** Required if > 10 patients affected.

---

## RB-03: Celery Task Queue Backup

**Trigger:**

- Alert: Celery queue depth > 1,000 tasks in any queue
- Alert: Task processing rate < 50% of normal for > 5 minutes
- Notifications not being delivered
- Payout processing delayed
- Slot generation not running

**Severity:** P1  
**Impact:** Notifications delayed, payouts delayed, slot generation lagging.

### Immediate Actions (< 5 minutes)

```bash
# 1. Check queue depths
celery -A Veridian inspect stats | grep -A5 "pool"

# Via Redis directly
redis-cli -u $REDIS_URL LLEN celery           # Default queue
redis-cli -u $REDIS_URL LLEN high_priority    # Notifications, payments
redis-cli -u $REDIS_URL LLEN low_priority     # Slot generation

# 2. Check if workers are running
celery -A Veridian inspect ping
# Expected: pong from each worker

# 3. Check Railway for worker process status
railway status --service celery-worker
```

### Diagnosis Steps

```bash
# Identify what tasks are stuck
celery -A Veridian inspect reserved

# Check for tasks in error / retry loop
celery -A Veridian inspect active

# Check worker logs for errors
railway logs --service celery-worker --tail 200

# Common root causes:
# - Worker crashed and was not restarted
# - A task is in an infinite retry loop
# - Redis connection issues (check Redis health)
# - A long-running task is blocking workers (check active tasks)

# Check Redis health
redis-cli -u $REDIS_URL PING
redis-cli -u $REDIS_URL INFO memory | grep used_memory_human
```

### Resolution Steps

```bash
# OPTION A: Worker crashed — restart
railway restart --service celery-worker

# OPTION B: Task in infinite retry loop — identify and purge
celery -A Veridian inspect reserved  # Find the stuck task ID
celery -A Veridian control revoke <task-id> --terminate

# Prevent the specific task from requeuing
celery -A Veridian control revoke <task-id> --terminate --signal SIGKILL

# OPTION C: Queue overwhelmed by a burst (e.g. mass notification event)
# Scale up workers temporarily
railway scale --service celery-worker --replicas 3
# Return to 1 when queue drains

# OPTION D: Redis memory full
redis-cli -u $REDIS_URL INFO memory
# If used_memory > maxmemory:
# 1. Check for stale keys:
redis-cli -u $REDIS_URL --scan --pattern 'celery-task-meta-*' | wc -l
# 2. Flush expired task results (safe — results are not operationally required)
python manage.py shell -c "
from django_celery_results.models import TaskResult
from django.utils import timezone
from datetime import timedelta
deleted = TaskResult.objects.filter(
    date_done__lt=timezone.now() - timedelta(days=7)
).delete()
print(f'Deleted {deleted[0]} old task results')
"

# OPTION E: Beat scheduler not running (scheduled tasks not firing)
railway status --service celery-beat
railway restart --service celery-beat
```

### Verification

```bash
# Queue depths should be draining
redis-cli -u $REDIS_URL LLEN celery
redis-cli -u $REDIS_URL LLEN high_priority

# Trigger a test task and confirm it processes
python manage.py shell -c "
from core.tasks import health_check_task
result = health_check_task.apply_async()
print(result.get(timeout=10))
"
# Expected: 'ok'
```

**Post-mortem:** Required if queue backup lasted > 30 minutes or > 100 tasks unprocessed.

---

## RB-04: Database Connection Exhaustion

**Trigger:**

- Alert: `django_db_connections_active` > 90% of pool max
- HTTP 500 errors with `OperationalError: FATAL: remaining connection slots are reserved`
- Railway health check failing
- Sentry spike in `django.db.utils.OperationalError`

**Severity:** P0  
**Impact:** API completely unavailable. All requests fail.

### Immediate Actions (< 5 minutes)

```bash
# 1. Confirm connection exhaustion
psql $DATABASE_URL -c "
SELECT count(*), state
FROM pg_stat_activity
WHERE datname = 'postgres'
GROUP BY state
ORDER BY count DESC;
"
# Look for large number of 'idle' or 'idle in transaction' connections

# 2. Identify connection hogs
psql $DATABASE_URL -c "
SELECT pid, usename, application_name, state, query_start,
       now() - query_start AS duration, left(query, 80) AS query_preview
FROM pg_stat_activity
WHERE datname = 'postgres'
  AND state != 'idle'
ORDER BY query_start ASC
LIMIT 20;
"

# 3. Immediately terminate long-running idle connections (> 5 minutes idle)
psql $DATABASE_URL -c "
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = 'postgres'
  AND state = 'idle'
  AND now() - state_change > INTERVAL '5 minutes';
"
```

### Diagnosis Steps

```bash
# Check PgBouncer pool status (Supabase manages this)
# Go to Supabase dashboard → Database → Connection Pooling

# Check if a specific service is leaking connections
psql $DATABASE_URL -c "
SELECT application_name, count(*) as connections
FROM pg_stat_activity
WHERE datname = 'postgres'
GROUP BY application_name
ORDER BY connections DESC;
"

# Common causes:
# - Django not using connection pooling (missing CONN_MAX_AGE setting)
# - Long-running transactions not being committed
# - Celery workers with too many processes, each holding a connection
# - A slow query blocking other queries (check pg_locks)
psql $DATABASE_URL -c "
SELECT
  blocked.pid AS blocked_pid,
  blocking.pid AS blocking_pid,
  left(blocked.query, 80) AS blocked_query,
  left(blocking.query, 80) AS blocking_query
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
  ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;
"
```

### Resolution Steps

```bash
# OPTION A: Terminate the blocking query
psql $DATABASE_URL -c "SELECT pg_cancel_backend(<blocking_pid>);"
# If cancel doesn't work:
psql $DATABASE_URL -c "SELECT pg_terminate_backend(<blocking_pid>);"

# OPTION B: Celery workers using too many connections
# Reduce Celery concurrency temporarily
railway variables set CELERY_CONCURRENCY=2 --service celery-worker
railway restart --service celery-worker

# OPTION C: Django not pooling connections — verify CONN_MAX_AGE
# Should be set in Django settings:
# DATABASES['default']['CONN_MAX_AGE'] = 60  (60 second pool)
# If missing, add and redeploy

# OPTION D: Emergency — kill ALL non-platform connections to restore service
psql $DATABASE_URL -c "
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = 'postgres'
  AND pid != pg_backend_pid()
  AND application_name NOT LIKE '%supabase%';
"
# Then immediately redeploy Django to reconnect cleanly

# OPTION E: Raise Supabase connection pool size (temporary, costs money)
# Go to Supabase dashboard → Settings → Database → Connection pool size
# Increase from default to max_connections × 0.8
```

### Verification

```bash
psql $DATABASE_URL -c "
SELECT count(*) FROM pg_stat_activity WHERE datname = 'postgres';
"
# Should be well below Supabase's connection limit

# API health check should pass
curl https://api.Veridian.app/api/v1/health
# Expected: {"status": "healthy", "db": "ok", ...}
```

**Post-mortem:** Always required. Connection exhaustion indicates a systemic issue that will recur.

---

## RB-05: Health Record Encryption Key Rotation

**Trigger:**

- Scheduled rotation (every 90 days per Document 6 key rotation schedule)
- Suspected key exposure (must be treated as P0)

**Severity:** P2 (scheduled) / P0 (emergency rotation after suspected exposure)

**Key model:** Per-patient keys are derived via HKDF from `HEALTH_RECORD_MASTER_KEY` + `patient_profiles.patient_key_salt`. A rotation event rotates the **master key only**; patient salts stay put. The job re-derives old and new per-patient keys on the fly and re-encrypts each entry. See `veridian-implementation-plan.md` Data Protection section for details.

### Pre-Rotation Checklist

```
□ Maintenance window scheduled and communicated (minimum 1 hour)
□ Database backup completed and verified
□ New master key generated (256-bit random): openssl rand -hex 32
□ New master key stored in Railway as HEALTH_RECORD_MASTER_KEY_NEW
□ Salts in patient_profiles confirmed non-null (SELECT COUNT(*) WHERE patient_key_salt IS NULL = 0)
□ Migration script tested in staging with production-scale data
□ Rollback procedure confirmed (old master retained in a sealed vault for 7 days)
□ On-call engineer standing by
```

### Rotation Steps

```python
# management/commands/rotate_health_record_keys.py

# Step 1: Enable maintenance mode (returns 503 to all write endpoints)
railway variables set MAINTENANCE_MODE=true --service api
railway redeploy --service api

# Step 2: Run the re-encryption migration
python manage.py rotate_health_record_keys \
  --old-master $HEALTH_RECORD_MASTER_KEY \
  --new-master $HEALTH_RECORD_MASTER_KEY_NEW \
  --batch-size 100 \
  --dry-run   # Run dry-run first to estimate time

# Dry-run output:
# Found 14,832 entries across 3,217 patients to re-encrypt
# Estimated time at 100/batch: ~25 minutes
# No changes made (dry-run)

# Step 3: Run actual rotation with progress logging
python manage.py rotate_health_record_keys \
  --old-master $HEALTH_RECORD_MASTER_KEY \
  --new-master $HEALTH_RECORD_MASTER_KEY_NEW \
  --batch-size 100
```

```python
# The rotation command implementation
class Command(BaseCommand):
    def handle(self, *args, **options):
        old_master = bytes.fromhex(options['old_master'])
        new_master = bytes.fromhex(options['new_master'])
        dry_run = options['dry_run']
        batch_size = options['batch_size']

        # Iterate patient-by-patient so we only derive two keys per patient.
        patients = PatientProfile.objects.all().iterator(chunk_size=batch_size)
        total_entries = HealthTimelineEntry.objects.filter(deleted_at__isnull=True).count()
        self.stdout.write(
            f'Found {total_entries} entries across {PatientProfile.objects.count()} patients'
        )

        if dry_run:
            self.stdout.write('No changes made (dry-run)')
            return

        processed = 0
        errors = 0
        for patient in patients:
            old_patient_key = derive_patient_key(old_master, patient.patient_key_salt)
            new_patient_key = derive_patient_key(new_master, patient.patient_key_salt)
            entries = HealthTimelineEntry.objects.filter(
                patient_id=patient.user_id, deleted_at__isnull=True
            )
            for entry in entries:
                try:
                    plaintext = decrypt(entry.content_encrypted, entry.content_iv, old_patient_key)
                    entry.content_encrypted, entry.content_iv = encrypt(plaintext, new_patient_key)
                    entry.save(update_fields=['content_encrypted', 'content_iv'])
                    processed += 1
                except Exception as e:
                    errors += 1
                    self.stderr.write(f'Error on entry {entry.id}: {e}')

            # Zero the derived keys before moving to the next patient
            old_patient_key = new_patient_key = None
            self.stdout.write(f'Progress: {processed}/{total_entries} ({errors} errors)')

        self.stdout.write(f'Complete: {processed} re-encrypted, {errors} errors')
        if errors > 0:
            self.stdout.write('WARNING: Some entries could not be re-encrypted. Check Sentry logs.')
```

```bash
# Step 4: Verify re-encryption succeeded
python manage.py verify_health_record_encryption \
  --master $HEALTH_RECORD_MASTER_KEY_NEW \
  --sample-size 100  # Decrypts 100 random entries (across multiple patients) to verify readability

# Step 5: Promote new master to primary
railway variables set HEALTH_RECORD_MASTER_KEY=$HEALTH_RECORD_MASTER_KEY_NEW --service api
railway variables unset HEALTH_RECORD_MASTER_KEY_NEW --service api

# Step 6: Disable maintenance mode
railway variables unset MAINTENANCE_MODE --service api
railway redeploy --service api

# Step 7: Revoke old key (remove it from all records in key management)
# Old key is no longer stored anywhere — rotation is complete
```

### Verification

```bash
# Confirm a sample of entries decrypt correctly with new key
python manage.py shell -c "
from health_records.models import HealthTimelineEntry
import random
sample = random.sample(list(HealthTimelineEntry.objects.values_list('id', flat=True)), 10)
for entry_id in sample:
    entry = HealthTimelineEntry.objects.get(id=entry_id)
    content = entry.content  # Triggers decryption with current key
    assert isinstance(content, dict), f'Entry {entry_id} failed to decrypt'
print('All 10 sampled entries decrypted successfully')
"
```

---

## RB-06: Slot Generation Task Failure

**Trigger:**

- Alert: `slots_generated_last_24h = 0` (nightly job produced no slots)
- Alert: Doctor availability showing as empty for the next 7 days despite active templates
- `generate_slots` Beat task not in Celery's scheduled task list

**Severity:** P2  
**Impact:** New bookings cannot be made for affected doctors. Existing bookings unaffected.

### Diagnosis Steps

```bash
# 1. Check when slots were last generated
psql $DATABASE_URL -c "
SELECT MAX(created_at) AS last_slot_created,
       MIN(slot_date) AS earliest_available,
       MAX(slot_date) AS furthest_available,
       COUNT(*) AS total_available_slots
FROM slots
WHERE status = 'available'
  AND slot_date >= CURRENT_DATE;
"

# 2. Check if the Beat task is scheduled
celery -A Veridian inspect scheduled
# Look for: generate_slots_nightly

# 3. Check Beat logs
railway logs --service celery-beat --tail 100 | grep "generate_slots"

# 4. Check the last task result
psql $DATABASE_URL -c "
SELECT task_name, status, date_done, result
FROM django_celery_results_taskresult
WHERE task_name = 'slots.tasks.generate_slots'
ORDER BY date_done DESC
LIMIT 5;
"

# 5. Check if the failure is for all doctors or specific ones
psql $DATABASE_URL -c "
SELECT
  dp.id AS doctor_id,
  u.full_name AS doctor_name,
  COUNT(s.id) AS future_available_slots
FROM doctor_profiles dp
JOIN users u ON u.id = dp.user_id
LEFT JOIN slots s ON s.doctor_profile_id = dp.id
  AND s.slot_date >= CURRENT_DATE
  AND s.status = 'available'
WHERE dp.verification_status = 'verified'
  AND dp.is_profile_active = true
GROUP BY dp.id, u.full_name
HAVING COUNT(s.id) = 0
ORDER BY u.full_name;
"
```

### Resolution Steps

```bash
# OPTION A: Beat not running — restart
railway restart --service celery-beat

# OPTION B: Task erroring — fix and re-trigger manually
python manage.py shell -c "
from slots.tasks import generate_slots
result = generate_slots.apply_async()
print('Task ID:', result.id)
print('Result:', result.get(timeout=300))  # Wait up to 5 minutes
"

# OPTION C: Specific doctor's templates broken — regenerate for that doctor only
python manage.py shell -c "
from slots.tasks import generate_slots_for_template
from slots.models import AvailabilityTemplate

templates = AvailabilityTemplate.objects.filter(
    doctor_profile_id='<DOCTOR_ID>',
    is_active=True,
)
for t in templates:
    generate_slots_for_template.apply_async(args=[str(t.id)])
    print(f'Queued generation for template {t.id}')
"

# OPTION D: All templates need regeneration (full re-run)
python manage.py generate_all_slots --from-date today --days 60 --batch-size 50
```

### Verification

```bash
psql $DATABASE_URL -c "
SELECT
  MAX(slot_date) AS furthest_slot,
  COUNT(*) AS new_slots_available
FROM slots
WHERE status = 'available'
  AND slot_date >= CURRENT_DATE
  AND created_at > NOW() - INTERVAL '30 minutes';
"
# Should show slots up to ~60 days out
```

---

## RB-07: Doctor No-Show Surge

**Trigger:**

- Alert: `no_show_doctor_count_last_1h` > 3
- Multiple patients reporting doctor not available at appointment time
- Platform admin receives complaints within the same time window

**Severity:** P1  
**Impact:** Multiple patients have paid and traveled to clinics with no doctor. High trust damage.

### Immediate Actions (< 5 minutes)

```bash
# Identify all affected appointments in the last 2 hours
psql $DATABASE_URL -c "
SELECT
  a.id AS appointment_id,
  u_patient.full_name AS patient_name,
  u_patient.phone AS patient_phone,
  u_doctor.full_name AS doctor_name,
  c.name AS clinic_name,
  s.slot_date,
  s.start_time,
  a.status
FROM appointments a
JOIN users u_patient ON u_patient.id = a.patient_id
JOIN doctor_profiles dp ON dp.id = a.doctor_profile_id
JOIN users u_doctor ON u_doctor.id = dp.user_id
JOIN slots s ON s.id = a.slot_id
LEFT JOIN clinic_affiliations ca ON ca.id = a.clinic_affiliation_id
LEFT JOIN clinics c ON c.id = ca.clinic_id
WHERE a.status = 'no_show_doctor'
  AND a.no_show_marked_at > NOW() - INTERVAL '2 hours'
ORDER BY s.slot_date, s.start_time;
"

# Check if this is one doctor or multiple
psql $DATABASE_URL -c "
SELECT
  dp.id,
  u.full_name,
  COUNT(*) AS no_show_count
FROM appointments a
JOIN doctor_profiles dp ON dp.id = a.doctor_profile_id
JOIN users u ON u.id = dp.user_id
WHERE a.status = 'no_show_doctor'
  AND a.no_show_marked_at > NOW() - INTERVAL '24 hours'
GROUP BY dp.id, u.full_name
HAVING COUNT(*) >= 2
ORDER BY no_show_count DESC;
"
```

### Resolution Steps

```bash
# Step 1: If one doctor is responsible — suspend immediately
python manage.py suspend_doctor \
  --doctor-id <DOCTOR_ID> \
  --reason "Multiple no-shows. Account under review." \
  --cancel-future-appointments \
  --notify-patients

# Step 2: Issue refunds for all affected patients
python manage.py process_no_show_doctor_refunds \
  --doctor-id <DOCTOR_ID> \
  --dry-run  # Review first

python manage.py process_no_show_doctor_refunds --doctor-id <DOCTOR_ID>

# Step 3: Offer priority rebooking credits
python manage.py issue_rebooking_credit \
  --patient-ids $(psql $DATABASE_URL -t -c "
    SELECT STRING_AGG(patient_id::text, ',')
    FROM appointments
    WHERE status = 'no_show_doctor'
    AND doctor_profile_id = '<DOCTOR_ID>'
    AND no_show_marked_at > NOW() - INTERVAL '24 hours';
  ") \
  --credit-amount 5000  # GHS 50 credit

# Step 4: Flag doctor for investigation
python manage.py flag_doctor_for_review \
  --doctor-id <DOCTOR_ID> \
  --reason "3+ no-shows in 24 hours"
```

### Communication

- **Affected patients (immediate, < 10 minutes):** "We sincerely apologise. Dr. [Name] was unable to attend your appointment. A full refund has been issued and a GHS 50 credit has been added to your account for your next booking."
- **Doctor:** Formal notice of suspension pending investigation.
- **Clinic (if applicable):** Notify clinic admin of suspension.

---

## RB-08: Payment Refund Stuck in Pending

**Trigger:**

- Alert: `refund_pending_over_24h` count > 0
- Patient reports: "It's been 3 days and I haven't received my refund"

**Severity:** P2  
**Impact:** Financial — patient funds withheld longer than communicated.

### Diagnosis Steps

```bash
# Find all stuck refunds
psql $DATABASE_URL -c "
SELECT
  pt.id,
  pt.provider_reference,
  pt.provider,
  pt.amount,
  pt.refunded_amount,
  pt.status,
  pt.refunded_at,
  pt.provider_response->>'refund' AS refund_details,
  a.patient_id,
  u.full_name,
  u.phone
FROM payment_transactions pt
JOIN appointments a ON a.id = pt.appointment_id
JOIN users u ON u.id = a.patient_id
WHERE pt.status IN ('refunded', 'partially_refunded')
  AND pt.refunded_at < NOW() - INTERVAL '24 hours'
  AND (pt.provider_response->>'refund_settled' IS NULL
       OR pt.provider_response->>'refund_settled' = 'false')
ORDER BY pt.refunded_at ASC;
"

# Check Paystack for refund status directly
python manage.py shell -c "
import requests
ref = '<PROVIDER_REFERENCE>'
r = requests.get(
    f'https://api.paystack.co/refund',
    params={'transaction': ref},
    headers={'Authorization': 'Bearer \$PAYSTACK_SECRET_KEY'}
)
print(r.json())
"
```

### Resolution Steps

```bash
# OPTION A: Refund initiated but not yet settled (Paystack takes 3-10 business days)
# No action needed — inform patient of timeline
python manage.py send_refund_status_update \
  --transaction-id <TRANSACTION_ID> \
  --estimated-days 5

# OPTION B: Refund was not actually initiated (task failed silently)
python manage.py shell -c "
from payments.services import process_refund
result = process_refund('<TRANSACTION_ID>', '<AMOUNT_IN_PESEWAS>', 'Retry refund')
print(result)
"

# OPTION C: Paystack rejected the refund (e.g. original charge was already reversed by bank)
# Check provider_response for rejection reason
# If charge was reversed: patient already has their money — notify them
python manage.py notify_patient_refund_status \
  --patient-id <PATIENT_ID> \
  --message "Your bank has already reversed this charge. No additional refund is needed."

# OPTION D: Bank account details changed — Paystack transfer failed
# Paystack typically retries 3 times then marks as failed
# Re-initiate with updated bank details if patient has registered new account
```

---

## RB-09: OTP Delivery Failure (Termii Outage)

**Trigger:**

- Alert: `otp_delivery_failure_rate` > 20% in any 5-minute window
- Multiple users reporting "I didn't receive my OTP"
- Termii status page shows degradation: https://status.termii.com

**Severity:** P1  
**Impact:** No new logins possible. Existing logged-in users unaffected (JWT still valid).

### Immediate Actions (< 5 minutes)

```bash
# 1. Confirm Termii is the issue
curl -X POST https://api.ng.termii.com/api/sms/send \
  -H "Content-Type: application/json" \
  -d '{
    "to": "+233000000000",
    "from": "Veridian",
    "sms": "Test",
    "type": "plain",
    "api_key": "'$TERMII_API_KEY'",
    "channel": "dnd"
  }'
# If this fails or times out, Termii is down.

# 2. Check circuit breaker status
redis-cli -u $REDIS_URL GET termii_circuit_breaker_state
# 'open' means circuit breaker has tripped — OTP sends are already paused

# 3. Check failure rate
redis-cli -u $REDIS_URL GET termii_failure_count
```

### Resolution Steps

```bash
# OPTION A: Termii is down — activate fallback SMS provider (e.g. Hubtel or Africa's Talking)
railway variables set SMS_PROVIDER=hubtel --service api
railway variables set HUBTEL_API_KEY=<key> --service api
railway redeploy --service api

# Verify fallback is working:
python manage.py send_test_otp --phone +233000000000 --provider hubtel

# OPTION B: Only specific channels down on Termii (e.g. 'dnd' channel)
# Switch to alternative channel in settings
railway variables set TERMII_CHANNEL=generic --service api
railway redeploy --service api

# OPTION C: Termii is back — reset circuit breaker and restore
redis-cli -u $REDIS_URL DEL termii_circuit_breaker_state termii_failure_count
railway variables set SMS_PROVIDER=termii --service api
railway redeploy --service api
```

### Communication

- **Web app:** Banner: "SMS delivery is temporarily delayed. Please try again in a few minutes or log in with Google."
- **If outage > 30 minutes:** Proactively email users who attempted login during outage with instructions.

---

## RB-10: Supabase Realtime Disconnection at Scale

**Trigger:**

- Alert: `realtime_active_connections` drops > 50% in < 1 minute
- Mobile users reporting slot availability not updating
- Appointment status changes not reflected in real-time on mobile

**Severity:** P2  
**Impact:** Mobile app falls back to polling. No data loss. UX degraded — slot availability may appear stale.

### Diagnosis Steps

```bash
# Check Supabase Realtime status
# https://status.supabase.com/

# Check current connection count in Supabase dashboard
# → Database → Realtime → Active connections

# Check if the issue is Supabase-wide or Flutter-specific
# Review Sentry for WebSocket connection errors in Flutter
sentry-cli events list --project Veridian-flutter --query "realtime" --limit 20

# Confirm polling fallback is working
# Mobile app should automatically fall back to 30-second polling
# Check API server logs for increased /slots endpoint traffic
railway logs --service api | grep "GET /api/v1/doctors" | tail -20
```

### Resolution Steps

```bash
# OPTION A: Supabase Realtime is down — polling fallback is automatic
# No action needed on the application side
# Monitor Supabase status page and notify users if outage > 30 minutes

# OPTION B: Flutter client has a subscription bug causing mass disconnect
# Deploy a Flutter OTA update via Firebase App Distribution (if configured)
# Or force-reduce the reconnect interval to trigger reconnection
railway variables set REALTIME_RECONNECT_INTERVAL_SECONDS=5 --service api
# (Flutter reads this from app config on next poll)

# OPTION C: Supabase Realtime connection limit reached
# Check Supabase plan connection limits
# Increase plan or reduce subscriptions per client
# (Mobile should only subscribe to own appointments + saved doctor slots)

# Verify clients are not over-subscribing:
# Review Flutter RealtimeService code for subscription leak
```

### Communication

- No user communication required for < 10-minute outages (fallback polling is transparent).
- If > 30 minutes: "Slot availability is refreshing every 30 seconds instead of in real-time. We're working on restoring live updates."

---

## RB-11: High Memory / OOM on Django Worker

**Trigger:**

- Alert: Django process memory > 85% of container limit
- Railway triggers OOM kill and restarts the container
- Sentry shows `MemoryError` or sudden spike in 503 errors

**Severity:** P1  
**Impact:** API intermittently unavailable during restarts.

### Diagnosis Steps

```bash
# Check memory trend in Railway metrics dashboard
# → Services → API → Metrics → Memory

# Check for memory leaks via Sentry
sentry-cli events list --project Veridian-api --query "MemoryError" --limit 10

# Profile memory usage (run against staging first)
python manage.py shell -c "
import tracemalloc
tracemalloc.start()
# ... run suspect operation ...
snapshot = tracemalloc.take_snapshot()
top_stats = snapshot.statistics('lineno')
for stat in top_stats[:10]:
    print(stat)
"

# Common causes:
# - Large QuerySet loaded into memory without pagination
# - PDF generation (WeasyPrint) not releasing memory after generation
# - Celery tasks accumulating results in memory
# - Profile embedding generation holding large numpy arrays
```

### Resolution Steps

```bash
# OPTION A: Immediate — restart the API to clear memory
railway restart --service api

# OPTION B: QuerySet memory issue — force chunking
# Find the offending view in Sentry traceback
# Replace: MyModel.objects.all()
# With: MyModel.objects.all().iterator(chunk_size=100)

# OPTION C: WeasyPrint OOM — offload to dedicated worker
# Move PDF generation to a separate low-memory Celery queue
railway variables set PDF_WORKER_QUEUE=pdf_queue --service api

# OPTION D: Scale vertically (temporary)
# Upgrade Railway container memory plan
# Revert after fix is deployed

# OPTION E: Gunicorn worker recycling
railway variables set GUNICORN_MAX_REQUESTS=1000 --service api
railway variables set GUNICORN_MAX_REQUESTS_JITTER=100 --service api
railway redeploy --service api
# Workers restart every 1000 requests — prevents memory accumulation
```

---

## RB-12: JWT Signing Key Compromise

**Trigger:**

- Security team discovers signing key in a public repository
- Unusual API activity suggesting forged tokens
- Alert: API requests with unusual role claims

**Severity:** P0  
**Impact:** Anyone who has the signing key can impersonate any user.

### Immediate Actions (< 5 minutes — do not delay)

```bash
# 1. IMMEDIATELY rotate the JWT signing key
# Generate new RS256 key pair:
openssl genrsa -out jwt_private_new.pem 2048
openssl rsa -in jwt_private_new.pem -pubout -out jwt_public_new.pem

# 2. Update Railway environment variables
railway variables set JWT_PRIVATE_KEY="$(cat jwt_private_new.pem)" --service api
railway variables set JWT_PUBLIC_KEY="$(cat jwt_public_new.pem)" --service api

# 3. Redeploy immediately — this invalidates ALL existing tokens
railway redeploy --service api
# NOTE: This will log out every user on every device.
# This is intentional and necessary.

# 4. Add old key to blocklist (prevent use even if someone is mid-session)
# All tokens signed with old key will fail signature verification after redeploy.
# No additional blocklist entry needed — key rotation is sufficient.

# 5. Securely delete the compromised key files
shred -u jwt_private_new.pem jwt_public_new.pem
```

### Diagnosis Steps (run in parallel with or after key rotation)

```bash
# Analyse API logs for suspicious activity using old key
# Look for: unusual roles, impossible geographic patterns, bulk data access
railway logs --service api --since 24h | grep '"role":"platform_admin"' > admin_access.log
# Review admin_access.log for unexpected actors

# Check audit_log for any actions taken under suspicious tokens
psql $DATABASE_URL -c "
SELECT actor_id, action, table_name, COUNT(*) as actions, MIN(created_at), MAX(created_at)
FROM audit_log
WHERE created_at > NOW() - INTERVAL '24 hours'
GROUP BY actor_id, action, table_name
HAVING COUNT(*) > 20  -- Unusually high activity
ORDER BY actions DESC;
"

# If suspicious admin actions found, review and potentially revert
```

### Communication

- **All users (immediate):** Push notification + email: "For your security, we've updated our systems. Please log in again."
- Do NOT mention key compromise in the user-facing message.
- **If data access confirmed:** Follow RB-15 (Health Data Breach) protocol.

**Post-mortem:** Always required. Determine how key was exposed and add controls to prevent recurrence.

---

## RB-13: Fake Doctor Profile Discovered Post-Verification

**Trigger:**

- Patient reports doctor is not a real doctor
- 3+ patient reports on the same doctor within 7 days
- Admin discovers license number is fraudulent

**Severity:** P0  
**Impact:** Patients received medical advice from an unqualified individual. Patient safety and legal liability.

### Immediate Actions (< 5 minutes)

```bash
# 1. Immediately suspend the doctor
python manage.py suspend_doctor \
  --doctor-id <DOCTOR_ID> \
  --reason "Verification fraud — license found to be invalid" \
  --cancel-future-appointments \
  --notify-patients

# 2. Confirm suspension
psql $DATABASE_URL -c "
SELECT verification_status, is_profile_active
FROM doctor_profiles WHERE id = '<DOCTOR_ID>';
"
# Expected: verification_status = 'suspended', is_profile_active = false
```

### Diagnosis and Evidence Gathering

```bash
# 3. Collect all patient interactions for legal record
psql $DATABASE_URL << 'EOF'
SELECT
  a.id AS appointment_id,
  u.full_name AS patient_name,
  u.phone,
  u.email,
  a.status,
  a.booking_mode,
  a.actual_start_time,
  a.actual_end_time,
  s.slot_date
FROM appointments a
JOIN users u ON u.id = a.patient_id
JOIN slots s ON s.id = a.slot_id
WHERE a.doctor_profile_id = '<DOCTOR_ID>'
  AND a.status IN ('completed', 'in_progress', 'confirmed')
ORDER BY s.slot_date;
EOF

# 4. Check for any health timeline entries authored by this doctor
psql $DATABASE_URL -c "
SELECT id, patient_id, entry_type, created_at
FROM health_timeline_entries
WHERE authored_by = (
  SELECT user_id FROM doctor_profiles WHERE id = '<DOCTOR_ID>'
)
AND deleted_at IS NULL;
"
```

### Resolution Steps

```bash
# 5. Notify all patients who had completed appointments
python manage.py notify_fake_doctor_patients \
  --doctor-id <DOCTOR_ID> \
  --message-template fake_doctor_patient_notice
# Template: "We have discovered that [Name], who you consulted with on [Date],
# was not a licensed medical professional. We strongly encourage you to
# consult a qualified doctor. A full refund has been processed."

# 6. Process full refunds for all completed appointments
python manage.py refund_all_doctor_appointments \
  --doctor-id <DOCTOR_ID> \
  --dry-run
python manage.py refund_all_doctor_appointments --doctor-id <DOCTOR_ID>

# 7. Flag health timeline entries authored by this doctor
psql $DATABASE_URL -c "
UPDATE health_timeline_entries
SET visibility = 'patient_only',
    title = CONCAT('[REQUIRES REVIEW] ', COALESCE(title, '')),
    updated_at = NOW()
WHERE authored_by = (
  SELECT user_id FROM doctor_profiles WHERE id = '<DOCTOR_ID>'
)
AND deleted_at IS NULL;
"

# 8. Preserve all evidence (do NOT delete account)
# Account moves to 'suspended' — physical deletion waits for legal team
```

### Communication

- **Affected patients:** Individual direct phone call attempt first (within 1 hour), then SMS + email.
- **Regulatory notification:** Notify Ghana Medical and Dental Council and Ghana Data Protection Commission within 72 hours.
- **Legal team:** Immediate notification for potential criminal referral.
- **Public statement:** Prepared only if media enquiry — do not proactively publish.

**Post-mortem:** Always required. Review the KYC process and identify how a fraudulent license passed review.

---

## RB-14: Railway Deployment Failure / Rollback

**Trigger:**

- Health check failing after deployment
- Spike in 5xx errors after deployment
- Critical bug discovered in just-deployed code

**Severity:** P1  
**Impact:** API degraded or unavailable.

### Resolution Steps

```bash
# 1. Immediately roll back to previous deployment
railway rollback --service api
# This redeploys the previous Docker image with the previous code.
# Takes < 2 minutes on Railway.

# 2. Verify rollback succeeded
curl https://api.Veridian.app/api/v1/health
# Expected: {"status": "healthy"}

# 3. If rollback also fails (rare — indicates infrastructure issue):
railway status --service api
# Check Railway status page: https://status.railway.app

# 4. For migration rollback (if new migration broke the DB):
# Django migrations are the hardest to roll back.
# If migration was destructive (column dropped, table deleted):
# a. Restore from Supabase point-in-time backup
# b. This is a last resort — coordinate with entire team

# Always check before deploying:
# □ New migrations are additive only (never drop columns in the same deploy as code change)
# □ Two-phase migration: deploy migration first, then code, then cleanup migration later
```

### Communication

- **During outage:** Status page update (Instatus or similar): "We are experiencing issues and are working on a fix."
- **After resolution:** "The issue has been resolved. All systems are operating normally."

---

## RB-15: Health Data Breach Suspected

**Trigger:**

- Intrusion detection alert (unexpected bulk data access)
- Researcher or external report of data exposure
- Discovery of data in places it should not be (public forum, etc.)
- RB-12 identifies actual data access under compromised token

**Severity:** P0 — ALL HANDS  
**Impact:** Patient PHI potentially exposed. Legal, regulatory, and reputational emergency.

### Immediate Actions (< 15 minutes)

```bash
# 1. Isolate — revoke all active sessions immediately (rotates JWT key)
# Follow RB-12 immediate actions

# 2. Identify scope — what was accessed, by whom, and when
psql $DATABASE_URL << 'EOF'
-- Check for unusual timeline access
SELECT
  actor_id,
  table_name,
  action,
  COUNT(*) as record_count,
  MIN(created_at) as first_access,
  MAX(created_at) as last_access
FROM audit_log
WHERE created_at > NOW() - INTERVAL '72 hours'
  AND table_name IN ('health_timeline_entries', 'appointments', 'users', 'consent_grants')
GROUP BY actor_id, table_name, action
HAVING COUNT(*) > 50  -- Bulk access threshold
ORDER BY record_count DESC;
EOF

# 3. Preserve evidence — DO NOT wipe logs
# Export audit log for the suspected window to secure storage
psql $DATABASE_URL -c "\COPY (
  SELECT * FROM audit_log WHERE created_at > NOW() - INTERVAL '7 days'
) TO '/tmp/audit_log_evidence_$(date +%Y%m%d_%H%M%S).csv' CSV HEADER;"
# Upload to secure location outside Railway

# 4. Block suspected attacker IPs at Cloudflare immediately
# Cloudflare dashboard → Security → IP Access Rules → Block

# 5. Notify:
# - CTO: immediate phone call
# - Legal team: immediate notification
# - All engineers: war room in Slack #incident channel
```

### Timeline and Regulatory Requirements

| Action                                    | Deadline   | Owner               |
| ----------------------------------------- | ---------- | ------------------- |
| Internal incident declared                | T+0        | On-call engineer    |
| CTO notified                              | T+15 min   | On-call engineer    |
| Legal team notified                       | T+30 min   | CTO                 |
| Scope of breach determined                | T+4 hours  | Engineering lead    |
| Affected patients notified                | T+72 hours | Legal + Engineering |
| Ghana Data Protection Commission notified | T+72 hours | Legal               |
| Ghana Medical and Dental Council notified | T+72 hours | Legal               |
| Post-mortem published (internal)          | T+7 days   | Engineering lead    |

### Patient Notification (if breach confirmed)

```
Subject: Important Security Notice — Veridian

Dear [Patient Name],

We are writing to inform you of a security incident that may have affected
your account on Veridian.

What happened: [Brief, factual description without technical jargon]

What information may have been accessed: [Specific list — be precise]

What we are doing: [Specific remediation steps taken]

What you should do: [Concrete actions patient can take]

If you have questions, contact us at security@Veridian.app or call [number].

We sincerely apologise for this incident and are committed to maintaining
your trust.

[CEO Name]
Chief Executive Officer, Veridian
```

**Post-mortem:** Always required. External security audit required before any PHI is re-exposed.

---

## RB-16: Quarterly Backup Restore Drill

**Trigger:** Calendar-scheduled the first Wednesday of each quarter at 10:00 UTC. Also triggered on-demand after any schema migration flagged `irreversible=true`.

**Goal:** Prove that the most recent nightly Supabase PITR snapshot can be restored to a working state, the application boots against it, and timeline decryption still works end-to-end. An un-tested backup is not a backup.

**Roles:**

- DRI: on-call backend engineer
- Observer: a second engineer who records timings and signs off on the after-action report

**Steps:**

1. **Provision a scratch project.** In the Supabase dashboard create a new project `veridian-drill-YYYY-QN` in the same region as production. Do NOT reuse an existing project — a botched restore must not touch production.

2. **Trigger PITR restore.** Use Supabase's Point-In-Time Recovery to restore the production database as of the latest available snapshot (typically 00:05 UTC the same morning). Record the snapshot timestamp.

3. **Smoke-test the restored schema.** Connect via psql using the drill project credentials and run:

   ```sql
   SELECT COUNT(*) FROM users;
   SELECT COUNT(*) FROM appointments WHERE deleted_at IS NULL;
   SELECT COUNT(*) FROM health_timeline_entries;
   SELECT MAX(created_at) FROM audit_log;
   ```

   Each count must be within 5% of the production equivalent at the snapshot time. Record deltas.

4. **Verify encryption roundtrip.** Deploy the production Django image to a scratch Railway environment, pointing `DATABASE_URL` at the restored project and `HEALTH_RECORD_MASTER_KEY` at the current production master key (read-only copy from the vault; never write it to a non-ephemeral file). Run:

   ```
   python manage.py drill_decrypt_sample --limit 20
   ```

   The command picks 20 random `health_timeline_entries` and decrypts them. All 20 must decrypt successfully. A single failure means the drill has found a real problem — escalate.

5. **Verify audit log chain.** Run `python manage.py verify_audit_chain --from-archive` against the drill DB, comparing computed block heads to the WORM archive (read-only). The chain must match from the earliest archived block up to the snapshot timestamp.

6. **Exercise the application.** Using a seeded test user, run the Flutter e2e suite against the scratch backend with `BASE_URL` pointed at the drill project. Golden paths (login, search, book, view timeline) must pass.

7. **Record the timings.** In `docs/drills/YYYY-QN-restore.md`, record: snapshot timestamp, restore start, schema-smoke-test pass time, decrypt verification pass time, application smoke test pass time, total elapsed time. RTO target is 2 hours; exceeding it is a P2 bug against the DR process.

8. **Destroy the drill project.** Delete the scratch Supabase project and the scratch Railway environment. Keep the markdown report. The scratch project must not persist beyond 24 hours — it holds PHI copies.

9. **Publish the after-action report.** File in the shared #eng-ops channel and attach to the quarterly compliance review pack.

**Failure modes and what they mean:**

- **Schema restore fails / drift:** migration history is inconsistent. Freeze production migrations until understood.
- **Decrypt fails:** key rotation introduced a bug or `patient_key_salt` got corrupted during a backfill. Investigate before next rotation.
- **Chain mismatch:** treat as R-4 incident per threat model — possible tampering on the production side between the last archived block head and the snapshot.

---

## RB-17: Audit Log Chain Verification & Archive

**Trigger:** This runbook documents the behaviour of two always-on jobs, plus the manual incident path for a chain-mismatch alert.

**Goal:** Guarantee that the tamper-evidence scheme for `audit_log` (see threat model R-4) is continuously exercised and any chain break is detected and triaged.

### Always-on: the 15-minute archive job

A Celery beat task `audit.archive_chain` runs every 15 minutes. It:

1. Reads `audit_log` rows with `id > last_archived_id` (tracked in table `audit_chain_archive_state`).
2. Re-computes each row's expected `row_hash` from its fields and the prior row's hash; compares against the stored `row_hash`. Any mismatch raises `AuditChainMismatch` and pages security (P0). The job stops — no further archiving until the mismatch is triaged.
3. On match, writes a JSON block `{ from_id, to_id, from_hash, to_hash, row_count, signed_at, signature }` to the S3 bucket `veridian-audit-worm` with Object Lock in Compliance mode, 7-year retention. The bucket lives in a separate AWS account whose IAM is not accessible from the application account — compromising the application cloud cannot rewrite the archive.
4. The signature is produced by an AWS KMS asymmetric key; the public half is checked into the repo under `docs/audit-chain-public-key.pem` so that any auditor can verify historical blocks without access to our infrastructure.
5. Updates `audit_chain_archive_state.last_archived_id = to_id`.

### Always-on: the nightly full verification

A Celery beat task `audit.verify_full_chain` runs nightly at 03:30 UTC. It:

1. Streams every archived block from S3 in order.
2. For each block, re-reads the rows in `audit_log` for that id range and recomputes the chain locally.
3. Compares the recomputed `to_hash` against the archived `to_hash` for that block. Any mismatch pages security (P0) with the offending block range.
4. Publishes a Grafana metric `audit_chain_last_verified_at` — a missing heartbeat for > 26 hours is itself an alert.

### Incident path: chain-mismatch alert fires

1. **Freeze writes.** Set the app-level flag `AUDIT_CHAIN_INTEGRITY_SUSPECT=true`. The Django middleware short-circuits any non-idempotent request with HTTP 503 and the message "temporary maintenance". This prevents further rows from being written on top of a compromised chain.
2. **Snapshot immediately.** Take an out-of-band `pg_dump` of `audit_log` and upload to the WORM bucket. Do NOT delete anything.
3. **Diff.** For the offending block range, compute `row_hash` locally for each row and compare to the archived `to_hash` of the preceding block to pinpoint the first diverging row.
4. **Correlate.** Query the Supabase DDL audit stream (`logs.postgres_logs` with `event_type = 'alter'`) for the same time window — a privileged actor who disabled triggers will have left a DDL trace.
5. **Rotate.** Rotate the Supabase service role key, Django DB credentials, and any PAT that could have been used to run DDL.
6. **Report.** If personal data evidence rows were altered, this is a reportable breach under DPA 2012 section 30(1). The DPC must be notified within 72 h — use the notification template in RB-15.
7. **Restore.** Once the tampering actor and blast radius are understood, restore `audit_log` to the pre-tampering state from PITR + replay of subsequent legitimate writes (reconstructed from application logs). This is the only table for which selective restore is acceptable because it is append-only and chain-verified.
8. **Post-mortem.** Always required. Root-cause why a privileged path existed without mandatory dual-control.

### Drift detection SLOs

| Metric                             | Target                  | Alert                   |
| ---------------------------------- | ----------------------- | ----------------------- |
| `audit_chain_last_archived_lag_s`  | < 900 (15 min)          | > 1800 → P1             |
| `audit_chain_last_verified_at`     | heartbeat within 26 h   | missing > 26 h → P1     |
| `audit_chain_mismatch_total`       | 0                       | any increase → P0       |

---

## Monitoring Alerting Reference

All alerts below are configured in Grafana + Sentry with PagerDuty routing.

| Alert name                      | Condition                                  | Severity | Runbook |
| ------------------------------- | ------------------------------------------ | -------- | ------- |
| `double_booking_detected`       | Any slot with 2+ active appointments       | P1       | RB-01   |
| `payments_pending_over_15min`   | COUNT > 5                                  | P1       | RB-02   |
| `celery_queue_depth_high`       | Any queue > 1,000                          | P1       | RB-03   |
| `db_connections_critical`       | Active > 90% of pool                       | P0       | RB-04   |
| `slots_generated_last_24h_zero` | Count = 0                                  | P2       | RB-06   |
| `no_show_doctor_surge`          | Count > 3 in 1 hour                        | P1       | RB-07   |
| `refund_pending_over_24h`       | Count > 0                                  | P2       | RB-08   |
| `otp_failure_rate_high`         | > 20% in 5 min                             | P1       | RB-09   |
| `api_memory_critical`           | > 85% container limit                      | P1       | RB-11   |
| `admin_access_anomaly`          | Unusual role claim pattern                 | P0       | RB-12   |
| `bulk_health_data_access`       | > 50 timeline reads by one actor in 1 hour | P0       | RB-15   |
| `api_5xx_spike`                 | > 5% error rate for 2 min                  | P1       | RB-14   |
| `api_latency_p95_high`          | p95 > 1 second for 5 min                   | P2       | RB-11   |
| `termii_delivery_failure`       | > 20% failure in 5 min                     | P1       | RB-09   |
| `audit_chain_mismatch_total`    | any increase                               | P0       | RB-17   |
| `audit_chain_last_archived_lag` | > 1800 s                                   | P1       | RB-17   |
| `audit_chain_verify_stalled`    | no heartbeat > 26 h                        | P1       | RB-17   |
| `backup_drill_overdue`          | last drill > 100 days ago                  | P2       | RB-16   |

---

\*Next document: **Document 9 of 10 — Legal & Compliance (Ghana)\***  
_Data Protection Act 2012 obligations, GHS requirements for digital health platforms, telehealth regulatory status, NHIA considerations, Paystack licensing, and the specific consent and retention obligations for a health booking platform operating in Ghana._

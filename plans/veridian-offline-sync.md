# Veridian — Document 4 of 10: Offline Sync Conflict Resolution Rules

**Project:** Veridian All-in-One Service Booking Platform  
**Version:** 1.0.0  
**Status:** Authoritative — all Flutter sync engine behaviour derives from this document  
**Applies to:** Flutter mobile app only (Next.js web is online-only)

---

## Philosophy

Veridian mobile is **local-first, not offline-only**. The distinction matters:

- **Local-first** means the app reads from local storage always and writes to local storage first. The server is the source of truth, but the user never waits for the network to see their data.
- **Offline-only** would mean the app works indefinitely without sync, which is not a goal — health booking requires server confirmation for safety.

The result: the app must be fully usable without connectivity for browsing, reading, and queuing write operations. But certain operations (booking confirmation, payment, telehealth) require connectivity to complete and must surface this clearly to the user.

### Core Principle: Optimistic Local, Pessimistic Critical

| Operation category                                                                | Strategy                                                                              |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Reads (viewing appointments, doctor profiles, timeline)                           | Serve from local cache always. Refresh in background.                                 |
| Non-critical writes (saving a doctor, updating profile notes, notification prefs) | Apply locally immediately. Sync when online. Conflict = server wins silently.         |
| Critical writes (creating a booking, cancelling, completing a diagnosis note)     | Apply locally as "pending". Confirm with server on reconnect. Conflict = notify user. |
| Payment operations                                                                | Require connectivity. Block with clear offline message. Do not queue.                 |
| Telehealth session join                                                           | Require connectivity. Block with clear offline message.                               |

---

## Architecture Overview

### Components

```
┌─────────────────────────────────────────────────────┐
│                  Flutter App                         │
│                                                     │
│  ┌──────────────┐    ┌───────────────────────────┐  │
│  │  Riverpod    │    │   Repository Layer         │  │
│  │  Providers   │◄──►│   (one per domain)         │  │
│  └──────────────┘    └─────────┬─────────┬────────┘  │
│                                │         │           │
│                     ┌──────────▼──┐  ┌───▼─────────┐ │
│                     │  Local DB   │  │  Remote API  │ │
│                     │  (Drift/    │  │  (Dio +      │ │
│                     │   SQLite)   │  │   interceptor)│ │
│                     └──────────┬──┘  └───▲─────────┘ │
│                                │         │           │
│                     ┌──────────▼──────────▼────────┐ │
│                     │      Sync Engine              │ │
│                     │  ┌─────────────────────────┐  │ │
│                     │  │  Operation Queue (Drift) │  │ │
│                     │  └─────────────────────────┘  │ │
│                     │  ┌─────────────────────────┐  │ │
│                     │  │  Conflict Resolver       │  │ │
│                     │  └─────────────────────────┘  │ │
│                     │  ┌─────────────────────────┐  │ │
│                     │  │  Connectivity Monitor    │  │ │
│                     │  └─────────────────────────┘  │ │
│                     └───────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### Local Database Tables (Drift/SQLite)

These mirror a subset of the server schema, plus sync-specific columns:

```dart
// All local tables include these sync columns:
// - sync_status: SyncStatus (synced | pending | conflict | failed)
// - local_updated_at: DateTime
// - server_updated_at: DateTime? (null = not yet confirmed by server)
// - sync_attempts: int (incremented on each failed sync attempt)
// - sync_error: String? (last error message)
```

**Tables stored locally:**

| Table                    | Scope                                             | Sync direction                                            |
| ------------------------ | ------------------------------------------------- | --------------------------------------------------------- |
| `local_users`            | Own user + own patient profile                    | Server → local (read) + local → server (write own fields) |
| `local_doctors`          | Saved doctors + recently viewed (last 50)         | Server → local only                                       |
| `local_appointments`     | All own appointments (all statuses)               | Bidirectional                                             |
| `local_slots`            | Available slots for saved doctors (7 days)        | Server → local only                                       |
| `local_timeline_entries` | Own health timeline (all entries)                 | Bidirectional                                             |
| `local_offline_queue`    | Pending write operations                          | Local only — flushed to server                            |
| `local_saved_doctors`    | Saved doctor IDs                                  | Bidirectional                                             |
| `local_notifications`    | In-app notification feed (last 100)               | Server → local only                                       |
| `local_form_templates`   | Pre-consultation form templates for saved doctors | Server → local only                                       |
| `local_sync_metadata`    | Last sync timestamps per table                    | Local only                                                |

---

## Connectivity Monitoring

```dart
// sync/connectivity_monitor.dart

class ConnectivityMonitor {
  final StreamController<ConnectivityState> _controller;

  // States
  // - online: full connectivity, API reachable
  // - degraded: connected but API responding slowly (>3s)
  // - offline: no connectivity
  // - unknown: app just launched, not yet determined

  ConnectivityState _state = ConnectivityState.unknown;

  void start() {
    // 1. Listen to connectivity_plus for network interface changes
    Connectivity().onConnectivityChanged.listen(_onNetworkChanged);

    // 2. Every 30 seconds, ping the health endpoint to confirm API reachability
    //    (network interface up ≠ API reachable — e.g. captive portal)
    Timer.periodic(Duration(seconds: 30), (_) => _pingHealthCheck());

    // 3. After any failed API call, immediately re-check connectivity state
  }

  Future<void> _pingHealthCheck() async {
    try {
      final response = await Dio().get(
        'https://api.Veridian.app/api/v1/health',
        options: Options(
          sendTimeout: Duration(seconds: 5),
          receiveTimeout: Duration(seconds: 5),
        ),
      );
      _setState(response.statusCode == 200
          ? ConnectivityState.online
          : ConnectivityState.degraded);
    } on DioException {
      _setState(ConnectivityState.offline);
    }
  }
}
```

**Connectivity state drives UI:**

- `online` → normal app behaviour
- `degraded` → show subtle "Slow connection" banner; continue operating
- `offline` → show "You're offline" banner; disable payment and telehealth buttons; show queued operation count badge
- `unknown` → show nothing; resolve within 5 seconds of launch

---

## Operation Queue

Every write operation that can be deferred is serialised into the `local_offline_queue` table before being sent to the server.

### Queue Entry Schema

```dart
class OfflineOperation {
  final String id;               // UUID — idempotency key sent as X-Idempotency-Key header
  final OperationType type;      // Enum of all queueable operation types
  final String payload;          // JSON-encoded operation data
  final OperationPriority priority; // critical | standard | low
  final int attempts;            // Incremented on each failed attempt
  final String? lastError;       // Last error message
  final DateTime createdAt;
  final DateTime? lastAttemptAt;
  final int? linkedLocalId;      // Local record ID this operation affects
  final String? linkedEntityType; // 'appointment' | 'timeline_entry' | etc.
}

enum OperationType {
  // Appointments
  createAppointment,
  cancelAppointment,
  rescheduleAppointment,

  // Health timeline
  createTimelineEntry,
  updateTimelineEntry,
  deleteTimelineEntry,

  // Profile
  updateUserProfile,
  updatePatientProfile,

  // Doctors
  saveDoctor,
  unsaveDoctor,

  // Notifications
  markNotificationRead,
  markAllNotificationsRead,
  updateNotificationPreferences,

  // Consent
  grantConsent,
  revokeConsent,
}

enum OperationPriority {
  critical,  // Process first; user is waiting; max 3 retry attempts
  standard,  // Process in order; max 5 retry attempts
  low,       // Best-effort; max 10 retry attempts; can be dropped if stale
}
```

### Priority Assignment

| Operation type                  | Priority | Rationale                                           |
| ------------------------------- | -------- | --------------------------------------------------- |
| `createAppointment`             | critical | Slot hold expires; user is waiting for confirmation |
| `cancelAppointment`             | critical | Doctor/patient needs timely notification            |
| `rescheduleAppointment`         | critical | Slot hold on new slot expires                       |
| `createTimelineEntry`           | standard | Health data important but not time-critical         |
| `updateTimelineEntry`           | standard |                                                     |
| `deleteTimelineEntry`           | standard |                                                     |
| `updateUserProfile`             | standard |                                                     |
| `updatePatientProfile`          | standard |                                                     |
| `grantConsent`                  | standard |                                                     |
| `revokeConsent`                 | critical | Privacy action — user expects immediate effect      |
| `saveDoctor`                    | low      |                                                     |
| `unsaveDoctor`                  | low      |                                                     |
| `markNotificationRead`          | low      |                                                     |
| `markAllNotificationsRead`      | low      |                                                     |
| `updateNotificationPreferences` | low      |                                                     |

---

## Sync Engine

### Flush Algorithm

```dart
// sync/sync_engine.dart

class SyncEngine {
  final OfflineQueueDao _queue;
  final ApiClient _api;
  final ConflictResolver _resolver;
  final ConnectivityMonitor _connectivity;

  Future<void> flush() async {
    if (_connectivity.state != ConnectivityState.online &&
        _connectivity.state != ConnectivityState.degraded) {
      return; // Nothing to do offline
    }

    // Process critical operations first, then standard, then low
    for (final priority in OperationPriority.values) {
      final ops = await _queue.getPendingByPriority(priority);
      for (final op in ops) {
        await _processOperation(op);
      }
    }
  }

  Future<void> _processOperation(OfflineOperation op) async {
    try {
      final result = await _dispatch(op);
      await _queue.delete(op.id);
      await _resolver.onSuccess(op, result);
    } on ConflictException catch (e) {
      await _resolver.onConflict(op, e);
    } on NetworkException {
      await _queue.incrementAttempts(op.id);
      // Will retry on next flush
    } on FatalException catch (e) {
      await _resolver.onFatal(op, e);
      await _queue.delete(op.id); // Remove — unrecoverable
    }
  }

  Future<dynamic> _dispatch(OfflineOperation op) async {
    return switch (op.type) {
      OperationType.createAppointment =>
        _api.appointments.create(
          CreateAppointmentRequest.fromJson(jsonDecode(op.payload)),
          idempotencyKey: op.id, // X-Idempotency-Key header
        ),
      OperationType.cancelAppointment =>
        _api.appointments.cancel(
          appointmentId: jsonDecode(op.payload)['appointment_id'],
          reason: jsonDecode(op.payload)['reason'],
          idempotencyKey: op.id,
        ),
      // ... all other types
    };
  }
}
```

### Flush Triggers

The sync engine flushes the queue on these events:

| Trigger               | Conditions                                                    |
| --------------------- | ------------------------------------------------------------- |
| App foreground event  | `AppLifecycleState.resumed`                                   |
| Connectivity restored | `ConnectivityMonitor` emits `online` from `offline`/`unknown` |
| Periodic background   | Every 15 minutes while app is in foreground                   |
| Manual user action    | User taps "Retry sync" in the sync status UI                  |
| Post-login            | Immediately after successful authentication                   |

### Retry Policy

| Priority | Max attempts | Backoff strategy          | Stale threshold               |
| -------- | ------------ | ------------------------- | ----------------------------- |
| critical | 3            | Immediate, 30s, 2min      | 10 minutes (auto-notify user) |
| standard | 5            | 1min, 5min, 15min, 1h, 6h | 24 hours                      |
| low      | 10           | Exponential, cap 24h      | 7 days (auto-drop)            |

After exceeding max attempts, critical and standard operations are moved to `failed` status and the user is notified. Low-priority operations are silently dropped after the stale threshold.

---

## Conflict Scenarios

A conflict occurs when a locally queued operation cannot be applied because the server state has diverged from what the client assumed when it queued the operation.

### CONFLICT-1: Booking a slot that was taken while offline

**Scenario:**  
Patient selects slot, goes offline, fills out pre-consultation form, taps "Book." The slot was booked by another patient while they were offline.

**Detection:**  
Server returns HTTP 409 with `error.code = "SLOT_UNAVAILABLE"` when the queued `createAppointment` is flushed.

**Local state when queued:**  
A local appointment record was created with `sync_status = 'pending'` and `status = 'requested'`.

**Resolution strategy:**

```dart
// conflict_resolver.dart

Future<void> handleSlotUnavailable(
  OfflineOperation op,
  ConflictException error,
) async {
  final payload = CreateAppointmentRequest.fromJson(jsonDecode(op.payload));

  // 1. Delete the optimistic local appointment record
  await _localDb.appointments.deleteByLocalId(op.linkedLocalId);

  // 2. Fetch alternative slots for same doctor, same week
  final alternatives = await _api.doctors.getSlots(
    doctorId: payload.doctorProfileId,
    fromDate: payload.slotDate,
    toDate: payload.slotDate.add(Duration(days: 7)),
  );

  // 3. Notify user with actionable recovery
  await _notifier.showConflict(
    ConflictNotification(
      type: ConflictType.slotTaken,
      title: 'That slot was just taken',
      message: 'Someone else booked this slot while you were offline. '
               'Here are the next available times:',
      actions: [
        ConflictAction(
          label: 'See available slots',
          onTap: () => router.push('/doctors/${payload.doctorProfileId}/slots'),
        ),
        ConflictAction(label: 'Dismiss', onTap: () {}),
      ],
      alternativeSlots: alternatives,
    ),
  );
}
```

**User-visible outcome:**  
Bottom sheet appears with "That slot was just taken" and a list of the next 5 available slots for the same doctor. Pre-consultation form responses are preserved in memory so the patient can re-book without re-filling the form.

**Pre-consultation form preservation:**

```dart
// Store form responses in memory for recovery flow
class BookingRecoveryCache {
  static final Map<String, Map<String, dynamic>> _cache = {};

  static void store(String doctorId, Map<String, dynamic> formResponses) {
    _cache[doctorId] = formResponses;
  }

  static Map<String, dynamic>? retrieve(String doctorId) => _cache[doctorId];

  // Auto-expire after 30 minutes
  static void expireAfter(String doctorId, Duration duration) {
    Future.delayed(duration, () => _cache.remove(doctorId));
  }
}
```

---

### CONFLICT-2: Cancelling an appointment that is already terminal

**Scenario:**  
Patient queues a cancellation offline. While offline, the doctor already cancelled the same appointment (server-initiated). When sync runs, the appointment is already `cancelled_by_doctor`.

**Detection:**  
Server returns HTTP 409 with `error.code = "APPOINTMENT_ALREADY_TERMINAL"`.

**Resolution strategy:**

```dart
Future<void> handleAlreadyTerminal(
  OfflineOperation op,
  ConflictException error,
) async {
  // 1. Fetch actual server state
  final serverId = jsonDecode(op.payload)['appointment_id'];
  final serverAppointment = await _api.appointments.get(serverId);

  // 2. Update local record to match server truth
  await _localDb.appointments.upsert(
    AppointmentMapper.fromJson(serverAppointment),
  );

  // 3. Notify user — outcome is what they wanted (cancelled), but reason differs
  await _notifier.showInfo(
    InfoNotification(
      title: 'Appointment already cancelled',
      message: _cancelledByMessage(serverAppointment.status),
      // e.g. "Your doctor had already cancelled this appointment.
      //        A full refund has been processed."
    ),
  );
}

String _cancelledByMessage(AppointmentStatus status) => switch (status) {
  AppointmentStatus.cancelledByDoctor =>
    'Your doctor had already cancelled this appointment. '
    'A full refund has been processed.',
  AppointmentStatus.cancelledByPlatform =>
    'This appointment was cancelled by Veridian. '
    'A full refund has been processed.',
  _ => 'This appointment was already cancelled.',
};
```

**User-visible outcome:**  
Informational snackbar. No action required. The local appointment card updates to show the actual cancelled state with the correct actor and reason.

---

### CONFLICT-3: Reschedule — new slot no longer available

**Scenario:**  
Patient selects a new slot for rescheduling while offline. The new slot was taken before sync runs.

**Detection:**  
Server returns HTTP 409 with `error.code = "SLOT_UNAVAILABLE"` on the reschedule operation.

**Resolution strategy:**

```dart
Future<void> handleRescheduleSlotTaken(
  OfflineOperation op,
  ConflictException error,
) async {
  final payload = jsonDecode(op.payload);

  // 1. Revert local appointment to original slot
  //    (The reschedule was optimistic — original slot_id was preserved in payload)
  await _localDb.appointments.revertReschedule(
    appointmentLocalId: op.linkedLocalId,
    originalSlotId: payload['original_slot_id'],
  );

  // 2. Fetch alternatives
  final alternatives = await _api.doctors.getSlots(
    doctorId: payload['doctor_profile_id'],
    fromDate: DateTime.parse(payload['new_slot_date']),
    toDate: DateTime.parse(payload['new_slot_date']).add(Duration(days: 7)),
  );

  await _notifier.showConflict(
    ConflictNotification(
      type: ConflictType.rescheduleSlotTaken,
      title: 'Reschedule slot taken',
      message: 'The slot you selected for rescheduling is no longer available. '
               'Your original appointment is unchanged.',
      actions: [
        ConflictAction(
          label: 'Choose another slot',
          onTap: () => router.push(
            '/appointments/${payload["appointment_id"]}/reschedule',
          ),
        ),
        ConflictAction(label: 'Keep original time', onTap: () {}),
      ],
      alternativeSlots: alternatives,
    ),
  );
}
```

**User-visible outcome:**  
The appointment card reverts to the original slot visually. Bottom sheet offers alternative slots or the option to keep the original time.

---

### CONFLICT-4: Doctor profile deactivated or suspended while offline

**Scenario:**  
Patient has saved a doctor and books while offline. By the time sync runs, the doctor's profile has been suspended or deactivated.

**Detection:**  
Server returns HTTP 403 with `error.code = "DOCTOR_NOT_VERIFIED"` or HTTP 409 with `error.code = "DOCTOR_NOT_ACCEPTING"`.

**Resolution strategy:**

```dart
Future<void> handleDoctorUnavailable(
  OfflineOperation op,
  ConflictException error,
) async {
  final payload = jsonDecode(op.payload);

  // 1. Delete optimistic appointment
  await _localDb.appointments.deleteByLocalId(op.linkedLocalId);

  // 2. Update local doctor profile to reflect current server state
  try {
    final doctor = await _api.doctors.get(payload['doctor_profile_id']);
    await _localDb.doctors.upsert(DoctorMapper.fromJson(doctor));
  } catch (_) {
    // Doctor may be completely removed from discovery — mark as unavailable locally
    await _localDb.doctors.markUnavailable(payload['doctor_profile_id']);
  }

  // 3. Notify
  await _notifier.showConflict(
    ConflictNotification(
      type: ConflictType.doctorUnavailable,
      title: 'Doctor no longer available',
      message: 'Dr. ${payload["doctor_name"]} is no longer accepting appointments. '
               'Would you like to search for a similar doctor?',
      actions: [
        ConflictAction(
          label: 'Find similar doctors',
          onTap: () => router.push(
            '/doctors?specialization=${payload["specialization_slug"]}',
          ),
        ),
        ConflictAction(label: 'Dismiss', onTap: () {}),
      ],
    ),
  );
}
```

**User-visible outcome:**  
The saved doctor card shows an "Unavailable" badge. The booking is removed. Search is offered pre-filtered to the same specialization.

---

### CONFLICT-5: Timeline entry created offline, appointment linked appointment was cancelled

**Scenario:**  
Patient writes a symptom log while offline and links it to an upcoming appointment. The appointment was cancelled before sync. The entry itself is valid (symptom logs don't require an appointment), but the link is broken.

**Detection:**  
The server accepts the `createTimelineEntry` call but the linked `appointment_id` returns 404 (appointment is soft-deleted or cancelled). This is detected by the sync engine pre-validating FK references before dispatching.

**Pre-validation check (runs before flush for linked entities):**

```dart
// Before flushing createTimelineEntry operations,
// verify linked appointments still exist and are not terminal
Future<bool> _validateTimelineEntryLinks(OfflineOperation op) async {
  final payload = jsonDecode(op.payload);
  final appointmentId = payload['appointment_id'];
  if (appointmentId == null) return true; // No link — always valid

  final localAppt = await _localDb.appointments.getById(appointmentId);
  if (localAppt == null) {
    // Strip appointment link — create entry as standalone
    payload.remove('appointment_id');
    await _queue.updatePayload(op.id, jsonEncode(payload));
    return true;
  }

  if (AppointmentStatus.terminalStates.contains(localAppt.status)) {
    // Strip link and proceed
    payload.remove('appointment_id');
    await _queue.updatePayload(op.id, jsonEncode(payload));
    return true;
  }
  return true;
}
```

**Resolution strategy:**  
Strip the appointment link silently. Create the entry without the appointment association. No user notification required — the health data is preserved without interruption.

---

### CONFLICT-6: Profile update — field-level conflict

**Scenario:**  
Patient updates their profile offline (e.g., changes emergency contact). The same field was also updated on a different device while offline.

**Detection:**  
Server returns updated record whose `updated_at` is newer than the client's local `server_updated_at` for that record.

**Resolution strategy (field-level merge):**

```dart
// For profile updates, use field-level last-write-wins
// The server record's updated_at is compared per-field where possible
// For fields without per-field timestamps, use record-level updated_at

Future<void> handleProfileConflict(
  OfflineOperation op,
  UserProfile serverRecord,
) async {
  final localRecord = await _localDb.users.getOwn();
  final queuedPayload = UserProfileUpdate.fromJson(jsonDecode(op.payload));

  // Server wins for fields NOT in the queued update
  // Local wins for fields IN the queued update (user explicitly changed these)
  final merged = UserProfile(
    fullName: queuedPayload.fullName ?? serverRecord.fullName,
    preferredLanguage: queuedPayload.preferredLanguage ?? serverRecord.preferredLanguage,
    timezone: queuedPayload.timezone ?? serverRecord.timezone,
    dateOfBirth: queuedPayload.dateOfBirth ?? serverRecord.dateOfBirth,
    gender: queuedPayload.gender ?? serverRecord.gender,
    // avatar_storage_key: server wins always (upload is a separate flow)
    avatarStorageKey: serverRecord.avatarStorageKey,
  );

  // Apply merged record locally
  await _localDb.users.upsert(merged);

  // Resubmit only the conflicting queued fields to the server
  await _api.users.updateMe(queuedPayload);
}
```

**User-visible outcome:**  
Transparent — no notification. The user's explicitly queued changes are preserved and applied on top of server state.

---

### CONFLICT-7: Consent grant revoked by patient on another device while offline

**Scenario:**  
Patient revokes consent for Doctor A on their phone (offline). Meanwhile, the same patient revokes consent using the web app (online). When the phone reconnects, it tries to revoke consent that is already revoked.

**Detection:**  
Server returns HTTP 409 with `error.code = "CONSENT_ALREADY_REVOKED"` or HTTP 404.

**Resolution strategy:**

```dart
Future<void> handleConsentAlreadyRevoked(OfflineOperation op) async {
  // 1. Fetch current consent state from server and update locally
  final patientConsents = await _api.consent.listGrants();
  await _localDb.consentGrants.replaceAll(patientConsents);

  // 2. No user notification needed — desired state (revoked) already achieved
  // Simply drop the queued operation
  await _queue.delete(op.id);
}
```

**User-visible outcome:**  
Silent. The local consent list updates to match server truth. Desired outcome (revoked) is already achieved.

---

### CONFLICT-8: Notification preferences conflict

**Scenario:**  
User changes notification preferences offline on phone. Different preference change made on the web.

**Detection:**  
Detected during pull-sync: server `updated_at` for preferences is newer than local `server_updated_at`.

**Resolution strategy:**  
Server wins completely. Notification preferences are not mergeable (enabling on one device while disabling on another has no sensible merge). The server record replaces local. The queued preference update is dropped.

```dart
Future<void> handlePreferencesConflict(OfflineOperation op) async {
  // Server wins — pull and replace local
  final serverPrefs = await _api.notifications.getPreferences();
  await _localDb.notificationPreferences.replaceAll(serverPrefs);
  await _queue.delete(op.id);

  // Notify user their preference changes weren't saved (they conflicted)
  await _notifier.showInfo(
    InfoNotification(
      title: 'Notification settings updated',
      message: 'Your notification settings were updated on another device. '
               'Your changes here were not saved.',
    ),
  );
}
```

**User-visible outcome:**  
Brief snackbar informing the user that settings were synced from another device. The preferences screen refreshes to show server state.

---

### CONFLICT-9: Queued booking — payment window expired during offline period

**Scenario:**  
Patient queues a booking while offline. A slot reservation is created locally as `pending`. When connectivity is restored, the 10-minute reservation TTL has already expired on the server. The slot was never actually reserved because the booking was never sent while offline.

**Critical design decision:**  
**Bookings that require payment MUST NOT be queued.** The payment flow requires real-time communication with the payment provider (Paystack). A queued booking that arrives 15 minutes later would try to initiate payment on an expired slot — this is not recoverable cleanly.

**Prevention (not resolution):**

```dart
// In the booking flow, BEFORE creating a local pending appointment:
Future<BookingResult> createBooking(CreateAppointmentRequest request) async {
  if (_connectivity.state == ConnectivityState.offline) {
    // Bookings requiring payment cannot be queued — inform user immediately
    if (request.requiresPayment) {
      return BookingResult.requiresConnectivity(
        message: 'Booking requires an internet connection to process payment. '
                 'Please connect and try again.',
      );
    }

    // Pay-at-desk bookings CAN be queued (no payment TTL)
    return await _queueOfflineBooking(request);
  }

  // Online path: proceed normally
  return await _api.appointments.create(request);
}
```

**Pay-at-desk offline booking (exception):**  
For clinics that have `payment_mode = 'pay_at_desk'`, bookings CAN be queued offline because there is no payment TTL. These are queued as `critical` priority and flushed immediately on reconnect.

When flushed, if the slot is no longer available, CONFLICT-1 resolution applies.

**User-visible outcome for payment-required bookings:**  
An inline banner within the booking flow: "You're offline — connect to the internet to complete your booking." The booking confirmation button is disabled. The selected slot and filled form are preserved in memory for when connectivity returns.

---

### CONFLICT-10: Saved doctor deleted from platform while offline

**Scenario:**  
Patient has Doctor X saved locally. Doctor X's account is permanently deleted from the platform (rare, but possible — e.g., doctor requests account deletion). When the patient reconnects, their saved doctor reference is dangling.

**Detection:**  
During pull-sync, the saved-doctors list from the server no longer contains Doctor X. Or a fetch of Doctor X's profile returns 404.

**Resolution strategy:**

```dart
Future<void> handleSavedDoctorDeleted(String doctorProfileId) async {
  // 1. Remove from local saved_doctors
  await _localDb.savedDoctors.delete(doctorProfileId);

  // 2. Remove cached doctor profile (or mark as deleted)
  await _localDb.doctors.markDeleted(doctorProfileId);

  // 3. Cancel any pending operations referencing this doctor
  final pendingOps = await _queue.getByEntityId(doctorProfileId);
  for (final op in pendingOps) {
    if (op.type == OperationType.createAppointment) {
      await _queue.delete(op.id);
      await _localDb.appointments.deleteByLocalId(op.linkedLocalId);
    } else {
      await _queue.delete(op.id); // Drop all other ops for this doctor
    }
  }

  // 4. Notify user only if they had pending appointments
  final hadPendingAppts = pendingOps.any(
    (op) => op.type == OperationType.createAppointment
  );
  if (hadPendingAppts) {
    await _notifier.showConflict(
      ConflictNotification(
        type: ConflictType.doctorUnavailable,
        title: 'Doctor no longer on Veridian',
        message: 'A doctor you had saved is no longer on Veridian. '
                 'Your pending booking has been cancelled.',
        actions: [
          ConflictAction(
            label: 'Find a new doctor',
            onTap: () => router.push('/doctors'),
          ),
        ],
      ),
    );
  }
}
```

---

## Pull Sync Strategy

Pull sync (server → local) runs on every connectivity restore and every app foreground event. It refreshes local data from the server.

### Pull Sync Algorithm

```dart
class PullSyncService {
  Future<void> syncAll() async {
    await Future.wait([
      _syncAppointments(),
      _syncTimeline(),
      _syncSavedDoctors(),
      _syncNotifications(),
      _syncSlotsForSavedDoctors(),
      _syncUserProfile(),
    ]);
    await _localDb.syncMetadata.updateLastSyncAt(DateTime.now());
  }

  Future<void> _syncAppointments() async {
    final lastSync = await _localDb.syncMetadata.getLastSyncAt('appointments');
    final updates = await _api.appointments.list(
      updatedSince: lastSync,
      pageSize: 100,
    );

    for (final serverAppt in updates) {
      final localAppt = await _localDb.appointments.getByServerId(serverAppt.id);

      if (localAppt == null) {
        // New appointment from server (e.g. booked on web) — insert locally
        await _localDb.appointments.insert(
          AppointmentMapper.toLocal(serverAppt, syncStatus: SyncStatus.synced),
        );
        continue;
      }

      if (localAppt.syncStatus == SyncStatus.pending) {
        // Local write in queue — do NOT overwrite local with server
        // The operation queue will handle this record
        continue;
      }

      // No pending local write — server wins, update local
      await _localDb.appointments.upsert(
        AppointmentMapper.toLocal(serverAppt, syncStatus: SyncStatus.synced),
      );
    }
  }

  // Key rule: NEVER overwrite a record whose syncStatus = 'pending'
  // during pull sync. The push sync (queue flush) will handle those records.
}
```

### Pull Sync Frequency

| Data type                         | Pull frequency                                    | Max staleness  |
| --------------------------------- | ------------------------------------------------- | -------------- |
| Appointments                      | Every app foreground + every 60s while foreground | 60 seconds     |
| Slot availability (saved doctors) | Every app foreground + every 30s while foreground | 30 seconds     |
| Health timeline                   | Every app foreground                              | 5 minutes      |
| Notifications                     | Every app foreground + Supabase Realtime          | Near real-time |
| Doctor profiles (saved)           | Once per app foreground                           | 1 hour         |
| User profile                      | Once per session                                  | Session        |

### Supabase Realtime Subscriptions

These are active while the app is in foreground and online:

```dart
void _setupRealtimeSubscriptions() {
  // Appointment status changes (patient's own appointments)
  _supabase
    .from('appointments')
    .stream(primaryKey: ['id'])
    .eq('patient_id', currentUserId)
    .listen((data) => _onAppointmentRealtime(data));

  // Slot availability changes (saved doctors' slots)
  for (final doctorId in _savedDoctorIds) {
    _supabase
      .from('slots')
      .stream(primaryKey: ['id'])
      .eq('doctor_profile_id', doctorId)
      .gte('slot_date', DateTime.now().toIso8601String().substring(0, 10))
      .listen((data) => _onSlotsRealtime(doctorId, data));
  }
}

void _onAppointmentRealtime(List<Map<String, dynamic>> data) {
  for (final row in data) {
    final serverId = row['id'];
    final localAppt = _localDb.appointments.getByServerId(serverId);

    // If a pending local write exists, don't overwrite it
    if (localAppt?.syncStatus == SyncStatus.pending) return;

    _localDb.appointments.upsert(
      AppointmentMapper.toLocalFromRaw(row, syncStatus: SyncStatus.synced),
    );
  }
}
```

---

## Conflict Resolver — Summary Table

| Conflict                               | ID   | Detection                                   | Resolution                                         | User notification                                   |
| -------------------------------------- | ---- | ------------------------------------------- | -------------------------------------------------- | --------------------------------------------------- |
| Slot taken at booking                  | C-1  | 409 SLOT_UNAVAILABLE                        | Delete optimistic appt, show alternatives          | Bottom sheet with next available slots              |
| Appt already terminal at cancel        | C-2  | 409 APPOINTMENT_ALREADY_TERMINAL            | Sync server state locally                          | Snackbar: "Already cancelled by [actor]"            |
| Reschedule slot taken                  | C-3  | 409 SLOT_UNAVAILABLE on reschedule          | Revert to original slot, show alternatives         | Bottom sheet with alternatives                      |
| Doctor suspended/deactivated           | C-4  | 403 DOCTOR_NOT_VERIFIED                     | Delete optimistic appt, mark doctor unavailable    | Bottom sheet: "Doctor unavailable, search similar?" |
| Timeline entry appointment link broken | C-5  | Pre-validation FK check                     | Strip appointment_id, create as standalone         | Silent — no notification                            |
| Profile field-level conflict           | C-6  | updated_at comparison                       | Local wins for queued fields, server wins for rest | Silent                                              |
| Consent already revoked                | C-7  | 409 / 404 on revoke                         | Fetch server state, drop op                        | Silent — desired outcome achieved                   |
| Notification preferences conflict      | C-8  | updated_at comparison                       | Server wins completely                             | Snackbar: "Settings synced from another device"     |
| Payment booking queued offline         | C-9  | Prevention (not resolution)                 | Block at booking time, preserve form data          | Inline: "Connect to complete booking"               |
| Saved doctor deleted from platform     | C-10 | 404 on doctor fetch / missing in saved list | Remove locally, cancel pending booking ops         | Bottom sheet only if pending appt existed           |

---

## Sync Status UI

The Flutter UI surfaces sync state to the user in three places:

### 1. Global Sync Banner (AppBar or persistent top bar)

```dart
// Appears when connectivity.state == offline OR pending queue count > 0
Widget buildSyncBanner(SyncState state) {
  if (state.connectivity == ConnectivityState.offline) {
    return SyncBanner(
      color: Colors.amber,
      icon: Icons.cloud_off,
      text: 'You\'re offline',
      subtext: state.pendingCount > 0
        ? '${state.pendingCount} changes queued'
        : 'Browsing saved data',
    );
  }
  if (state.pendingCount > 0 && state.connectivity == ConnectivityState.online) {
    return SyncBanner(
      color: Colors.blue,
      icon: Icons.sync,
      text: 'Syncing ${state.pendingCount} changes...',
    );
  }
  return SizedBox.shrink(); // No banner when all synced and online
}
```

### 2. Appointment Card Pending Indicator

When an appointment has `syncStatus = 'pending'`, show a subtle "Pending sync" chip on the appointment card. When `syncStatus = 'failed'`, show a red "Sync failed — tap to retry" chip.

### 3. Sync Conflict Modal

For C-1, C-3, C-4, and C-10 (user-facing conflicts), a bottom sheet modal is shown with:

- Clear title stating what happened
- Explanation of what the system did automatically
- One or two clear action buttons
- Never more than two options — cognitive load during a health booking flow must be minimal

---

## Testing Strategy for the Sync Engine

### Unit tests (pure Dart, no Flutter)

- `ConflictResolver` — test each conflict scenario with mocked API responses
- `SyncEngine` — test flush ordering (critical before standard before low)
- `PullSyncService` — test the `syncStatus = pending` skip rule
- Retry policy — test backoff timing and max attempt exhaustion

### Integration tests (Flutter test with fake API)

- Full offline booking flow: queue → reconnect → flush → C-1 conflict → recovery
- Reschedule conflict: queue → conflict → revert → alternatives shown
- Multi-device conflict: simulate web update via fake server state change, verify pull sync

### Golden tests

- Sync banner in offline state
- Appointment card with `pending` sync badge
- Conflict bottom sheet for C-1
- Conflict bottom sheet for C-4

### Manual test scenarios (QA checklist)

| Scenario                              | Steps                                                                | Expected                                                               |
| ------------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Book while offline (pay-at-desk)      | Turn off wifi, book appt at pay-at-desk clinic, turn wifi on         | Booking syncs, confirmed state appears                                 |
| Book while offline (payment required) | Turn off wifi, tap Book Now for online payment                       | "Connect to book" message shown, button disabled                       |
| Slot taken conflict                   | Book while offline, manually take same slot on web, reconnect        | C-1 conflict modal shown, alternatives offered                         |
| Doctor suspended                      | Save doctor, go offline, admin suspends doctor on backend, reconnect | Doctor marked unavailable, any pending booking for that doctor removed |
| Cancel already-cancelled appt         | Cancel appt offline, cancel same appt on web, reconnect              | C-2 silent resolution, correct state shown                             |
| Profile update from two devices       | Update name on phone offline, update name on web, reconnect          | Phone's name update wins (was explicitly queued)                       |

---

## Files Produced

| File                       | Description                                                                              |
| -------------------------- | ---------------------------------------------------------------------------------------- |
| `Veridian-offline-sync.md` | This document — conflict scenarios, resolution strategies, and sync engine specification |

---

\*Next document: **Document 5 of 10 — Pre-Consultation Form Schema\***  
_The dynamic form builder data model — field types, conditional logic, validation rules, versioning, and the rendering contract between server and Flutter/Next.js clients._

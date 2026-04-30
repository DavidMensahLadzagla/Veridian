# Veridian — Document 6 of 10: Security Threat Model

**Project:** Veridian All-in-One Service Booking Platform  
**Version:** 1.0.0  
**Status:** Authoritative — all security controls, penetration testing scope, and incident response derive from this document  
**Framework:** STRIDE (Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege)  
**Classification:** Sensitive — restrict distribution to engineering and security personnel

---

## Threat Landscape Overview

Veridian operates at the intersection of three high-value target categories:

1. **Personal health information (PHI)** — health timelines, diagnoses, prescriptions, lab results. In Ghana, this is sensitive under the Data Protection Act 2012 and carries reputational risk disproportionate to financial loss.
2. **Financial transactions** — Paystack payment flows, doctor payouts, refund processing. Direct theft vector.
3. **Identity and trust** — unverified actors impersonating doctors, patients gaming the review system, clinic admins over-reaching their access scope.

The platform's security posture must be **defence-in-depth**: no single control failure should result in a breach. Every critical asset has at least three independent protection layers.

---

## Threat Actors

| Actor                              | Motivation                                                  | Capability                                         | Likely targets                                          |
| ---------------------------------- | ----------------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------- |
| **Opportunistic attacker**         | Financial gain, credential stuffing                         | Low — uses automated tools and public exploit kits | Patient accounts, payment data                          |
| **Targeted attacker**              | Specific patient's health data (e.g. journalist, executive) | Medium — social engineering, phishing, API abuse   | Health timeline of specific patient                     |
| **Malicious doctor**               | Fraudulent bookings, harvesting patient data                | Medium — legitimate API access                     | Patient contact info, health data of their own patients |
| **Malicious patient**              | Free consultations, competitor intelligence, harassment     | Low-Medium                                         | Review manipulation, doctor data scraping               |
| **Disgruntled employee / insider** | Data exfiltration, sabotage                                 | High — legitimate credential access                | Database, admin panel, financial records                |
| **Platform competitor**            | Business intelligence, doctor/patient poaching              | Medium                                             | Doctor profiles, booking volumes                        |
| **Automated scraper**              | Build competing database of doctor profiles                 | Low — scripted                                     | Public doctor discovery endpoints                       |
| **State actor** (low probability)  | Surveillance of specific individuals                        | Very high                                          | Health records of targeted individuals                  |

---

## System Trust Boundaries

```
[Public Internet]
      │
      ▼
[CDN / WAF — Cloudflare]          ← Boundary 1: Public perimeter
      │
      ▼
[Railway Load Balancer / TLS termination]  ← Boundary 2: Transport
      │
      ▼
[Django API]                       ← Boundary 3: Application logic
      │         │
      ▼         ▼
[Supabase DB] [Redis]              ← Boundary 4: Data stores
      │
      ▼
[Supabase Storage]                 ← Boundary 5: File storage
```

Every threat below is mapped to the boundary it attacks.

---

## STRIDE Threat Catalogue

---

### SPOOFING THREATS

---

#### S-1: OTP Interception — Impersonating a Patient

**Boundary:** 1 (transport), 3 (application)  
**Actor:** Opportunistic or targeted attacker  
**Attack:** Attacker intercepts the SMS OTP sent via Termii. On Ghana's mobile networks, SS7 vulnerabilities have been publicly documented. With the OTP, attacker logs into the patient's account, views health records, and potentially books appointments that create fraudulent charges.

**Likelihood:** Medium (SS7 attacks require carrier-level access; SIM-swap is more accessible)  
**Impact:** Critical — full account takeover, health record exposure, fraudulent charges

**Controls:**

| Layer      | Control            | Implementation                                                                                                                 |
| ---------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| Prevention | OTP entropy        | 6-digit numeric OTP with 300-second TTL. 3 attempts before lockout.                                                            |
| Prevention | Rate limiting      | Max 3 OTP send requests per phone number per hour. Redis-backed.                                                               |
| Prevention | OTP binding        | OTP is bound to the phone number AND a server-side session token returned at login initiation. Both must match at verify time. |
| Prevention | Device fingerprint | First login from a new device generates a notification to registered email (if present).                                       |
| Detection  | Anomaly detection  | Multiple failed OTP attempts across different phone numbers from same IP → temporary IP block. Alert to security dashboard.    |
| Recovery   | Account recovery   | Doctor/patient can report account compromise. Platform admin resets and re-verifies identity via alternative channel.          |

**Residual risk after controls:** Low

---

#### S-2: SIM Swap Attack — Full Account Takeover

**Boundary:** 1, 3  
**Actor:** Targeted attacker  
**Attack:** Attacker convinces mobile carrier to transfer victim's phone number to attacker-controlled SIM. Attacker then uses `POST /auth/login` → receives OTP → full account access.

**Likelihood:** Low-Medium (requires social engineering of carrier)  
**Impact:** Critical — full account takeover

**Controls:**

| Layer      | Control                   | Implementation                                                                                                                                                                                                                |
| ---------- | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Email-as-secondary factor | Users with email set receive a notification on every new device login. If they did not initiate, they can revoke all sessions via an email link (no OTP required for this action — it uses a time-limited HMAC signed token). |
| Prevention | Trusted device list       | After first successful login, device token is stored. New device logins generate a "New device login" alert.                                                                                                                  |
| Prevention | Session anomaly           | If a new session appears from a different geographic IP within 5 minutes of a previous session, the previous sessions are invalidated and the user is notified.                                                               |
| Detection  | Login pattern monitoring  | Flag logins from a new SIM-associated device immediately following a period of inactivity.                                                                                                                                    |
| Mitigation | Quick revocation          | Users can revoke all active sessions from the account settings screen without requiring a second factor.                                                                                                                      |

**Residual risk after controls:** Low-Medium (SIM swap is a systemic telecom vulnerability; full prevention is not possible at the application layer)

---

#### S-3: JWT Token Theft — Session Hijacking

**Boundary:** 2, 3  
**Actor:** Any attacker with network access or XSS capability  
**Attack:** Attacker obtains a valid JWT access token via XSS on the web app, a compromised device, or network interception. Uses it to make API calls as the victim.

**Likelihood:** Low (requires active exploit; HTTPS mitigates network theft)  
**Impact:** High — API access for 15 minutes (access token TTL)

**Controls:**

| Layer      | Control                                  | Implementation                                                                                                                               |
| ---------- | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Short access token TTL                   | 15-minute expiry. Stolen token has narrow exploitation window.                                                                               |
| Prevention | Refresh token as HttpOnly cookie (web)   | JavaScript cannot read the refresh token. XSS cannot steal it.                                                                               |
| Prevention | Refresh token in secure storage (mobile) | `flutter_secure_storage` uses iOS Keychain / Android Keystore. Not accessible to other apps.                                                 |
| Prevention | Refresh token rotation                   | Every use of a refresh token invalidates it and issues a new one. Reuse of an old refresh token → full session revocation (indicates theft). |
| Prevention | HTTPS everywhere                         | TLS 1.2+ enforced. HSTS header set with 1-year max-age.                                                                                      |
| Prevention | Content Security Policy (web)            | Strict CSP prevents XSS injection. `script-src 'self'`; no `unsafe-inline`.                                                                  |
| Detection  | Refresh token reuse detection            | If a refresh token is used after rotation (replay), both the old and new sessions are immediately revoked. Admin alert fired.                |
| Detection  | Geo-velocity check                       | Access token used from a different country than issued → flag for review.                                                                    |

**Residual risk after controls:** Very Low

---

#### S-4: Doctor Profile Impersonation — Fake Verified Doctor

**Boundary:** 3  
**Actor:** Malicious actor seeking to conduct fraudulent consultations  
**Attack:** Actor registers as a doctor, uploads a fraudulent or stolen medical license, and gets listed as a verified doctor before the KYC review catches the fraud. Patients book appointments with a fake doctor.

**Likelihood:** Low-Medium (requires human effort; Ghana Medical Council license numbers are verifiable)  
**Impact:** Critical — patient safety, legal liability, platform reputation

**Controls:**

| Layer      | Control                        | Implementation                                                                                                                                                         |
| ---------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Manual KYC review              | No doctor profile goes live without a human admin reviewing the license against the Ghana Medical and Dental Council (GMDC) public registry. 24–48 hour review window. |
| Prevention | License database cross-check   | Admin dashboard includes a direct link to the GMDC license verification portal for each KYC submission. Future: automated API check when GMDC provides one.            |
| Prevention | License uniqueness constraint  | No two doctor profiles can have the same `license_number`. Duplicate triggers immediate flag.                                                                          |
| Prevention | Resubmission limit             | Maximum 3 KYC submissions. 4th attempt flags for investigation, not just review.                                                                                       |
| Prevention | Profile active gate            | `is_profile_active` defaults to `false` until `verification_status = 'verified'`. Cannot appear in search.                                                             |
| Detection  | Post-verification monitoring   | Patients can report a doctor as "not a real doctor" via a flagging mechanism. 3 reports within 7 days triggers automatic profile suspension and admin review.          |
| Detection  | Appointment outcome monitoring | Zero completion rate + high cancellation rate after few appointments → flags for review.                                                                               |

**Residual risk after controls:** Low

---

### TAMPERING THREATS

---

#### T-1: Slot Double-Booking via Race Condition

**Boundary:** 3, 4  
**Actor:** Two simultaneous legitimate users OR a single attacker sending concurrent requests  
**Attack:** Two patients submit `POST /appointments` for the same slot at the same millisecond. Without proper locking, both succeed and the doctor has two patients at the same time.

**Likelihood:** Medium (concurrent users are expected; race window is small but real)  
**Impact:** High — double-booking destroys trust, causes patient harm (patient shows up, no doctor)

**Controls:**

| Layer      | Control                    | Implementation                                                                                                                                                                                    |
| ---------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Pessimistic locking        | `SELECT ... FOR UPDATE` on the slot row within `transaction.atomic()`. One transaction holds the lock; the other waits. The second sees `status ≠ 'available'` and raises `SlotUnavailableError`. |
| Prevention | Unique constraint          | `UNIQUE(doctor_profile_id, slot_date, start_time)` on the slots table. Even if the application logic fails, the DB rejects the duplicate.                                                         |
| Prevention | Status machine enforcement | Slot status transitions are atomic. `available → reserved` is the only path to booking.                                                                                                           |
| Prevention | API rate limiting          | Max 5 booking attempts per patient per minute. Prevents automated concurrent submission.                                                                                                          |
| Detection  | Monitoring                 | Alert if any appointment is created with the same slot_id as an existing non-terminal appointment.                                                                                                |

**Residual risk after controls:** Very Low

---

#### T-2: Appointment Status Manipulation — Bypassing the State Machine

**Boundary:** 3  
**Actor:** Malicious patient or doctor  
**Attack:** Patient attempts to call `POST /appointments/{id}/complete` directly (to trigger a payout without a real consultation). Or doctor calls `POST /appointments/{id}/confirm` on someone else's appointment.

**Likelihood:** Low (requires knowledge of API; protected by auth)  
**Impact:** Medium — financial fraud, trust violation

**Controls:**

| Layer      | Control                    | Implementation                                                                                                                                                                                   |
| ---------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Prevention | Object-level authorization | Every state transition endpoint checks `appointment.patient_id == request.user.id` OR `appointment.doctor_profile.user_id == request.user.id` before processing.                                 |
| Prevention | Role checks                | `complete` and `start` require `role = 'doctor'`. `confirm` requires `role = 'doctor'` AND ownership.                                                                                            |
| Prevention | State machine enforcement  | Service layer checks current status before any transition. Invalid transitions raise `InvalidStateTransitionError`.                                                                              |
| Prevention | Guard conditions           | `start` requires `NOW() ≥ slot.start_time - 30 minutes`. Cannot start tomorrow's appointment today.                                                                                              |
| Detection  | Audit log                  | Every status transition is recorded in `appointment_status_history` with actor, timestamp, and from/to status. Anomalous patterns (e.g. completing an appointment with no start) trigger alerts. |

**Residual risk after controls:** Very Low

---

#### T-3: Payment Amount Tampering

**Boundary:** 3  
**Actor:** Malicious patient  
**Attack:** Patient intercepts the Paystack checkout flow and modifies the `amount` parameter client-side, paying a lower amount than the consultation fee. Or crafts a fake webhook claiming payment success.

**Likelihood:** Low-Medium (Paystack checkout is client-side; webhook forgery without HMAC is impossible)  
**Impact:** High — revenue loss, financial integrity

**Controls:**

| Layer      | Control                       | Implementation                                                                                                                                                                                                               |
| ---------- | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Server-side amount authority  | The `amount` sent to Paystack's initialize API is read from `clinic_affiliations.consultation_fee` in the database — never from the client request. The client cannot influence the amount.                                  |
| Prevention | Webhook HMAC validation       | Every Paystack webhook is validated against `x-paystack-signature` using the Paystack secret key via HMAC-SHA512. Invalid signature → 400, no processing.                                                                    |
| Prevention | Amount verification           | On `POST /payments/verify`, the server calls Paystack's verify endpoint and checks that `response.data.amount` equals `appointment.consultation_fee`. Mismatch → `PAYMENT_AMOUNT_MISMATCH` error, appointment not confirmed. |
| Prevention | Provider reference uniqueness | `provider_reference` has a UNIQUE constraint. Replay of the same Paystack reference is idempotent (already captured) — cannot be used to "double-confirm" an appointment.                                                    |
| Detection  | Amount discrepancy monitoring | Any payment where provider-reported amount ≠ expected amount is logged and alerted, even if rejected. Pattern of attempts triggers IP block.                                                                                 |

**Residual risk after controls:** Very Low

---

#### T-4: Health Record Tampering — Unauthorised Diagnosis Note

**Boundary:** 3, 4  
**Actor:** Malicious doctor trying to add notes to patients not their own  
**Attack:** Doctor calls `POST /appointments/{id}/diagnosis` on an appointment that belongs to a different doctor, adding false medical information to a patient's health record.

**Likelihood:** Low  
**Impact:** Critical — falsified medical records, patient harm, legal liability

**Controls:**

| Layer      | Control                        | Implementation                                                                                                                      |
| ---------- | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Appointment ownership check    | `POST /appointments/{id}/diagnosis` verifies `appointment.doctor_profile.user_id == request.user.id`.                               |
| Prevention | Appointment status gate        | Only `in_progress` or `completed` appointments accept diagnosis notes. Requested/confirmed appointments are locked.                 |
| Prevention | RLS on health_timeline_entries | Supabase RLS policy prevents any direct DB write to `health_timeline_entries` that doesn't come through the authenticated API path. |
| Prevention | Author field immutable         | `health_timeline_entries.authored_by` is set by the server from `request.user.id` — never from the request body.                    |
| Detection  | Audit log                      | Every `health_timeline_entries` INSERT is logged in `audit_log` with actor, appointment ID, and entry type.                         |
| Detection  | Patient visibility             | Patients see all entries on their timeline. A false entry would be visible to the patient who can dispute and report it.            |

**Residual risk after controls:** Very Low

---

#### T-5: Pre-Consultation Form Schema Injection

**Boundary:** 3  
**Actor:** Malicious doctor  
**Attack:** Doctor crafts a form template with a `pattern` field containing a ReDoS (Regular Expression Denial of Service) payload — a regex that causes catastrophic backtracking when evaluated against certain inputs. When a patient submits the form, the server hangs.

**Likelihood:** Low  
**Impact:** Medium — targeted DoS against the form validation service

**Controls:**

| Layer      | Control             | Implementation                                                                                                                                                                      |
| ---------- | ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Regex timeout guard | Pattern validation in Django runs with a 100ms timeout using `signal.alarm()`. Patterns exceeding this are rejected at template save time with `PATTERN_TOO_COMPLEX`.               |
| Prevention | Pattern allowlist   | Optional: only allow patterns that match a safe subset (anchored, no catastrophic backtracking constructs). Use the `redos` Python library to check for vulnerability at save time. |
| Prevention | Sandboxing          | Form validation runs in a separate Celery worker, not the API process. Even if a regex hangs, it affects only the worker, not the API.                                              |

**Residual risk after controls:** Very Low

---

### REPUDIATION THREATS

---

#### R-1: Doctor Denies Making a Diagnosis

**Boundary:** 3, 4  
**Actor:** Malicious doctor attempting to deny authoring a diagnosis note  
**Attack:** After entering a harmful or false diagnosis, doctor claims they never wrote it.

**Likelihood:** Low  
**Impact:** High — legal dispute, patient safety

**Controls:**

| Layer      | Control                | Implementation                                                                                                                                                |
| ---------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Immutable author field | `authored_by` is set server-side from the authenticated JWT claim. Cannot be set or changed by the client.                                                    |
| Prevention | Append-only history    | `health_timeline_entries` supports soft-delete only (sets `deleted_at`). The original record, content, and author are never physically deleted.               |
| Prevention | Audit log              | Every INSERT into `health_timeline_entries` is recorded in `audit_log` with the full before/after state, actor ID, IP address, and user agent.                |
| Evidence   | Timestamp integrity    | `created_at` is set by the database (`DEFAULT NOW()`), not the application. Cannot be spoofed by the client.                                                  |
| Evidence   | Appointment linkage    | Diagnosis notes are linked to a specific `appointment_id` with `actual_start_time` and `actual_end_time` set. The timeline of the consultation is verifiable. |

**Residual risk after controls:** Very Low

---

#### R-2: Patient Disputes a Booking They Made

**Boundary:** 3, 4  
**Actor:** Patient claiming they never made a booking to avoid a no-show fee  
**Attack:** Patient claims the booking was fraudulent to avoid penalty.

**Controls:**

| Layer    | Control               | Implementation                                                                                                                        |
| -------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Evidence | Booking audit trail   | `appointment_status_history` records `from=null, to=requested, actor=patient_id` with timestamp and IP.                               |
| Evidence | Pre-consultation form | Patient's answers are stored server-side at booking time. Existence of detailed form responses is evidence of genuine booking intent. |
| Evidence | Payment capture       | For paid bookings, Paystack's transaction record (with customer details) is independently verifiable.                                 |
| Evidence | Device and IP         | Booking IP and user agent are logged.                                                                                                 |

**Residual risk after controls:** Very Low

---

#### R-3: Payment Dispute — Doctor Claims Non-Payment

**Boundary:** 3, 4  
**Actor:** Doctor claims payment was not received for a completed consultation  
**Attack:** Doctor disputes that payment was made, demands second payment.

**Controls:**

| Layer    | Control                       | Implementation                                                                                                            |
| -------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Evidence | `payment_transactions` record | Immutable record with `provider_reference`, `status=captured`, `captured_at`, and full `provider_response` from Paystack. |
| Evidence | Payout record                 | `payouts` table records gross amount, platform fee deduction, net amount, and Paystack Transfer reference.                |
| Evidence | Appointment linkage           | `appointments.payment_transaction_id` links the consultation to the payment unambiguously.                                |

**Residual risk after controls:** Very Low

---

#### R-4: Silent Tampering of the Audit Log

**Boundary:** 5 (database)  
**Actor:** A malicious insider with direct database access (rogue DBA, compromised CI credentials, supply-chain breach reaching the Supabase service role key) attempts to cover tracks by editing or deleting rows in `audit_log`.  
**Attack:** Attacker issues `UPDATE audit_log SET after_state = ...` or `DELETE FROM audit_log WHERE id = ...` to erase their earlier actions, or silently rewrites `actor_id` to point at an innocent user.

**Likelihood:** Low  
**Impact:** Critical — every other repudiation control (R-1…R-3) relies on `audit_log` being ground truth. If it can be silently rewritten, the entire evidentiary chain collapses.

**Controls:**

| Layer      | Control                         | Implementation                                                                                                                                                                                                                                                                                                   |
| ---------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Append-only triggers            | `trg_audit_log_no_update`, `trg_audit_log_no_delete`, `trg_audit_log_no_truncate` raise `insufficient_privilege` on any attempt to mutate an existing row. A non-superuser cannot bypass these without first issuing `ALTER TABLE … DISABLE TRIGGER`, which itself is a detectable, audited DDL event.           |
| Prevention | Least-privilege DB roles        | The Django application role has `INSERT` on `audit_log` only; not `UPDATE`, `DELETE`, or `TRUNCATE`. The `authenticated` Supabase role has no access at all. `ALTER TABLE` is restricted to the migration role, used only by CI.                                                                                 |
| Detection  | Per-row SHA-256 hash chain      | Each row stores `prev_row_hash` (hash of the previous row) and `row_hash` (hash of its own canonical fields plus `prev_row_hash`). Altering any historic row invalidates every subsequent `row_hash`. The `audit_log_chain()` BEFORE INSERT trigger computes this server-side — clients cannot choose the hash. |
| Detection  | External WORM archive (RB-17)   | Every 15 minutes, a Celery job reads the newest contiguous block of `audit_log` rows, verifies the chain locally, and writes the block head hash, block range, and a detached signature to an S3 bucket with Object Lock (Compliance mode, 7-year retention). Rewriting history after the next sign-off is detectable by re-computing the chain and comparing to the archived head.     |
| Detection  | Daily verification job (RB-17)  | A nightly job replays the full chain from the earliest archived block head, compares each block's computed head to the archived signed head, and pages security on mismatch.                                                                                                                                    |
| Response   | Incident response runbook       | On chain-mismatch alert: (1) snapshot the database immediately, (2) rotate all service-role keys, (3) diff current rows against the last known-good archive block, (4) identify the altered row(s) and correlate with DDL and session audit logs, (5) report to the DPC within 72 h if personal data evidence was altered. |

**Residual risk after controls:** Low — tampering is detectable within 15 minutes and cryptographically proven after the fact; prevention is bypassable only by a superuser-level actor who also controls the WORM archive credentials (defence in depth: the archive bucket lives in a separate AWS account whose IAM is not accessible from the application's cloud account).

---

### INFORMATION DISCLOSURE THREATS

---

#### I-1: Patient Health Record Exposure via Broken Object-Level Authorisation (BOLA)

**Boundary:** 3  
**Actor:** Malicious patient or attacker  
**Attack:** Attacker knows (or enumerates) a victim's appointment UUID and calls `GET /appointments/{id}` directly, accessing another patient's health data and pre-consultation responses.

**Likelihood:** Medium (UUIDs are unpredictable but appointment IDs may leak via referral links, push notifications, etc.)  
**Impact:** Critical — health record breach

**Controls:**

| Layer      | Control                      | Implementation                                                                                                                                                                    |
| ---------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Object-level ownership check | Every appointment endpoint checks `appointment.patient_id == request.user.id` OR `appointment.doctor_profile.user_id == request.user.id`. UUID knowledge alone is not sufficient. |
| Prevention | Supabase RLS                 | Even if Django check is bypassed, RLS policy `patient_own_appointments` prevents the query from returning data for another patient. Dual enforcement.                             |
| Prevention | UUID unpredictability        | All primary keys are UUIDv4 (random, not sequential). 2^122 keyspace makes enumeration infeasible.                                                                                |
| Prevention | No sequential IDs in URLs    | No endpoint exposes sequential integers. No `GET /appointments/1234`.                                                                                                             |
| Prevention | Direct-read RLS audit        | Flutter/Next.js read a defined subset of tables directly from Supabase (bypassing Django). For that subset, RLS is the only authorisation layer. See **Appendix A — Supabase Direct-Read Tables** (below) for the canonical list and required RLS tests (veridian-test-strategy.md `TestTelehealthURLGate`, `TestTimelineRLS`, `TestRealtimeRLS`). |
| Detection  | Access anomaly               | If a request for a UUID returns 403 (exists but access denied), and the same IP makes 10+ such requests, trigger alert and temporary IP block.                                    |

**Residual risk after controls:** Very Low

---

#### I-2: Health Timeline Exposure via Consent Bypass

**Boundary:** 3, 4  
**Actor:** Malicious doctor  
**Attack:** Doctor calls `GET /patients/{patient_id}/timeline` for a patient they have no appointment with and no consent grant from. Attempts to access records of patients not their own.

**Likelihood:** Low-Medium (doctors have legitimate API access; temptation exists for patient research)  
**Impact:** Critical — systematic health data exposure

**Controls:**

| Layer      | Control                | Implementation                                                                                                                                                                             |
| ---------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Prevention | Consent grant check    | `GET /patients/{patient_id}/timeline` checks `consent_grants` table for a valid, non-revoked, non-expired grant before returning any data.                                                 |
| Prevention | Visibility filter      | Even with a valid consent grant, only entries where `visibility IN ('shared_with_current_doctor', 'shared_with_all_future_doctors')` are returned. Patient-only entries are never exposed. |
| Prevention | RLS double enforcement | Supabase RLS `timeline_doctor_consent_read` policy enforces the consent check at the database level. Django check + RLS = two independent enforcement layers.                              |
| Detection  | Access logging         | Every call to `GET /patients/{patient_id}/timeline` is logged with the requesting doctor's ID, the patient ID, and whether a valid consent grant existed. Reviewed weekly.                 |
| Detection  | Anomaly: volume        | A doctor requesting timelines for > 10 different patients per day triggers an alert. Normal clinical practice does not require this pattern.                                               |

**Residual risk after controls:** Very Low

---

#### I-3: Doctor Profile Enumeration / Scraping

**Boundary:** 1, 3  
**Actor:** Competitor, data broker  
**Attack:** Automated scraper calls `GET /doctors` with paginated requests, building a complete database of Veridian's doctor network, pricing, and availability.

**Likelihood:** High (public endpoint, no auth required)  
**Impact:** Medium — competitive intelligence, doctor poaching

**Controls:**

| Layer      | Control                         | Implementation                                                                                                                                                           |
| ---------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Prevention | Rate limiting (unauthenticated) | `GET /doctors` — max 60 requests per IP per minute, max 200 per hour. Redis-backed.                                                                                      |
| Prevention | Cloudflare Bot Management       | Cloudflare's bot score filters automated traffic at the CDN layer before it reaches Django. Suspicious traffic challenged with CAPTCHA.                                  |
| Prevention | Cursor-based pagination         | No `offset` parameter. Cursor tokens are opaque and expire after 5 minutes of inactivity. A scraper cannot resume from an arbitrary page offset.                         |
| Prevention | Selective field exposure        | `GET /doctors` (list) returns `DoctorProfileSummary` — not the full profile. Phone numbers and email addresses are never in any public endpoint.                         |
| Detection  | Volume monitoring               | > 500 unique doctor profile views from one IP in one hour → block and alert.                                                                                             |
| Mitigation | Attribution watermarking        | Optionally: inject subtle, unique identifier into profile response (e.g. slightly varied spacing in bio text) that allows tracing the source of a leaked scrape dataset. |

**Residual risk after controls:** Low-Medium (public information disclosure is inherent to a discovery platform; the goal is to raise the cost of scraping, not make it impossible)

---

#### I-4: Health Record Exposure via Insecure File URLs

**Boundary:** 3, 5  
**Actor:** Any attacker who obtains a file URL  
**Attack:** Attacker obtains a Supabase Storage URL for a lab result or prescription PDF (e.g. via a shared link, cached URL in a browser, or log file exposure). Uses the URL to access the file after the intended access period.

**Likelihood:** Low-Medium  
**Impact:** High — health data exposure without a database breach

**Controls:**

| Layer      | Control                   | Implementation                                                                                                                                                                                                       |
| ---------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Signed URLs only          | Health documents are in the `health-documents` private bucket. No public URLs exist. All access is via short-lived signed URLs (1-hour TTL) generated by the Django API.                                             |
| Prevention | RLS on storage bucket     | Supabase Storage RLS policy ensures only the file owner (patient) and the appointment's doctor can generate signed URLs for files in their path.                                                                     |
| Prevention | URL generation gating     | The Django API only generates a signed URL for a file if: (a) the requester is the file owner OR (b) the requester is the appointment's doctor AND the appointment is non-terminal AND a valid consent grant exists. |
| Prevention | Path structure            | Files stored at `health-documents/{patient_id}/{appointment_id}/{filename}`. The path itself contains no guessable component.                                                                                        |
| Detection  | Signed URL access logging | Supabase logs all signed URL accesses. Anomalous access patterns (multiple accesses from different IPs on the same URL) trigger review.                                                                              |

**Residual risk after controls:** Very Low

---

#### I-4b: Telehealth URL Premature Disclosure via Supabase Direct Read

**Boundary:** 3, 5
**Actor:** Authenticated appointment party (patient or doctor) who subscribes to the `appointments` table directly through Supabase Realtime or the Supabase client SDK.
**Attack:** The DRF serializer hides `telehealth_room_url` until `start_time - 15 min`, but Flutter also reads appointments directly via Supabase under RLS. Because the base RLS policy only checks party membership, the URL would be readable hours before the appointment. Leaked URL + room token can be joined by third parties.

**Likelihood:** Medium (path exists by default; trivially exploited by any curious user)
**Impact:** High — allows unauthorised observers to join a telehealth call.

**Controls:**

| Layer      | Control                               | Implementation                                                                                                                                                                         |
| ---------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Client-facing view `v_appointments_safe` | All Flutter and Next.js reads of appointments go through `v_appointments_safe` (defined in veridian_schema.sql). The view nulls `telehealth_room_url` / `telehealth_patient_url` until 15 minutes before the slot start. |
| Prevention | Revoke base-table SELECT from `authenticated` | `REVOKE SELECT ON appointments FROM authenticated;` — only the service role (Django) can read the raw table. `GRANT SELECT ON v_appointments_safe TO authenticated;`                    |
| Prevention | DRF serializer symmetric gate          | The Django serializer applies the same `start_time - 15 min` gate, so both read paths behave identically.                                                                               |
| Prevention | Token rotation                         | Daily.co room tokens are issued per user per session with a short expiry (≤ 2h). Even if leaked, the token is invalidated at room close.                                                 |
| Detection  | Audit log on URL access                | Every `SELECT` on the DRF `meeting_url` endpoint is audit-logged with `actor_id` and `appointment_id`. Anomalous access patterns (non-party actor, bulk reads) trigger alert `telehealth_url_access_anomaly`. |

**Residual risk after controls:** Low. Enforcement now lives in the database (view) AND the serializer — a single path can't leak.

---

#### I-5: API Error Message Information Leakage

**Boundary:** 3  
**Actor:** Any attacker  
**Attack:** API returns stack traces, SQL error messages, or internal field names in error responses. Attacker uses these to understand the database schema, discover internal endpoints, or tailor injection attacks.

**Likelihood:** Medium (common Django misconfiguration)  
**Impact:** Medium — intelligence gathering for more targeted attacks

**Controls:**

| Layer      | Control                       | Implementation                                                                                                                                                                        |
| ---------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | `DEBUG = False` in production | Django's `DEBUG` flag is `False` in all non-development environments. Stack traces never reach the HTTP response.                                                                     |
| Prevention | Custom exception handler      | All exceptions caught by a global DRF exception handler that maps to the standard error envelope `{ error: { code, message, request_id } }`. Raw exception details go to Sentry only. |
| Prevention | Generic error messages        | 500 errors return `{ error: { code: "INTERNAL_ERROR", message: "An unexpected error occurred." } }`. No internal details.                                                             |
| Prevention | `request_id` in errors        | The `request_id` in every error response maps to the Sentry trace. This allows debugging without exposing internals to the client.                                                    |

**Residual risk after controls:** Very Low

---

### DENIAL OF SERVICE THREATS

---

#### D-1: OTP Flooding — Termii Bill Exhaustion

**Boundary:** 1, 3  
**Actor:** Malicious actor  
**Attack:** Attacker calls `POST /auth/login` or `POST /auth/otp/resend` in a loop with real Ghanaian phone numbers (scraped from public sources). Each call sends a real SMS via Termii, running up the platform's SMS bill and potentially causing Termii to throttle or cut off service.

**Likelihood:** Medium  
**Impact:** High — financial loss (SMS cost), service degradation (legitimate users can't receive OTPs)

**Controls:**

| Layer      | Control                | Implementation                                                                                                                                                                             |
| ---------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Prevention | Per-phone rate limit   | Max 3 OTP sends per phone number per hour. Redis `INCR` + `EXPIRE`.                                                                                                                        |
| Prevention | Per-IP rate limit      | Max 10 OTP requests per IP per 10 minutes across all phone numbers.                                                                                                                        |
| Prevention | Cloudflare Turnstile   | Invisible CAPTCHA challenge on the login page (web). Automated submissions fail the challenge before reaching the API.                                                                     |
| Prevention | Honeypot phone numbers | A list of phone numbers that should never receive legitimate OTP requests (known test numbers, previously abused numbers). Requests to these trigger immediate IP block.                   |
| Prevention | Termii spend alert     | Termii account configured with a spend alert at 50% of monthly budget. Alert fires to engineering Slack channel.                                                                           |
| Detection  | Volume monitoring      | > 100 OTP sends per minute across all numbers → alert + rate limit tightening.                                                                                                             |
| Recovery   | Termii circuit breaker | If Termii API returns errors for 5 consecutive requests, a circuit breaker opens and OTP sends pause for 60 seconds. Users are shown "SMS delivery is delayed — please try again shortly." |

**Residual risk after controls:** Low

---

#### D-2: Slot Generation Task Exhaustion

**Boundary:** 3, 4  
**Actor:** Malicious doctor  
**Attack:** Doctor creates hundreds of availability templates in rapid succession. Each template creation triggers an immediate Celery task to generate 60 days of slots. This floods the Celery worker queue and PostgreSQL with bulk inserts, causing task queue backup and DB performance degradation.

**Likelihood:** Low  
**Impact:** Medium — platform slowdown for all users

**Controls:**

| Layer      | Control                      | Implementation                                                                                                                                                                                                    |
| ---------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Template creation rate limit | Max 10 availability template creations per doctor per hour.                                                                                                                                                       |
| Prevention | Max templates per doctor     | Hard limit of 50 active templates per doctor profile.                                                                                                                                                             |
| Prevention | Async generation throttle    | The immediate slot generation task for new templates is queued with a `countdown=30` — it does not run synchronously. Burst of template creations = burst of queued tasks that the worker drains at its own pace. |
| Prevention | Celery task priority         | Slot generation tasks run in a `low_priority` queue. Notification and payment tasks use `high_priority` queue. Slot generation cannot starve critical tasks.                                                      |
| Prevention | Database connection pool     | PgBouncer (via Supabase) limits concurrent DB connections. Bulk slot inserts use batch upsert, not individual inserts.                                                                                            |

**Residual risk after controls:** Very Low

---

#### D-3: Large File Upload DoS

**Boundary:** 3, 5  
**Actor:** Malicious patient  
**Attack:** Patient uploads a 1GB file to the pre-consultation form file upload endpoint, exhausting storage bandwidth, worker memory, or storage quota.

**Likelihood:** Low  
**Impact:** Medium — storage cost spike, potential service disruption

**Controls:**

| Layer      | Control                          | Implementation                                                                                                                                    |
| ---------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Client-side size check           | Flutter and Next.js validate `file.size <= max_file_size_mb * 1024 * 1024` before initiating upload. Instant rejection without a network request. |
| Prevention | Supabase Storage file size limit | Storage bucket configured with a 25MB maximum file size. Upload rejected at the storage layer regardless of client.                               |
| Prevention | MIME type validation             | Storage bucket `allowed_mime_types` policy. Binary executables and unknown types are rejected by storage before any bytes land on disk.           |
| Prevention | Per-patient storage quota        | Soft quota of 500MB per patient for health documents. Quota check runs before signed upload URL is issued.                                        |
| Prevention | Upload URL expiry                | Signed upload URLs expire after 5 minutes. A slow upload that doesn't complete is automatically invalidated.                                      |

**Residual risk after controls:** Very Low

---

#### T-6: Malicious File Upload (Malware, Polyglot, XSS in PDF)

**Boundary:** 3, 5
**Actor:** Patient, doctor, or malicious clinic admin
**Attack:** Attacker uploads a file with a benign MIME extension (e.g. `.pdf`, `.jpg`) that contains an embedded exploit — a crafted PDF with JavaScript, a polyglot file that parses as both an image and a script, or a well-known malware binary. When another party (doctor opening a patient's pre-consult PDF, or admin reviewing a KYC upload) opens the file, their device is compromised.

**Likelihood:** Medium — file sharing is a standard attack vector; any healthcare platform is a target.
**Impact:** High — compromise of a doctor or admin device can propagate to patient data and platform credentials.

**Controls:**

| Layer      | Control                      | Implementation                                                                                                                                                                                                |
| ---------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | MIME content-sniffing        | After upload, a Celery task runs `python-magic` / libmagic against the file to detect the actual content type and compare it to the declared MIME. Mismatches are quarantined and rejected.                   |
| Prevention | Antivirus scan               | Every uploaded file is scanned with ClamAV (or a cloud scanner such as Cloudflare R2 + VirusTotal) in a Celery task before it becomes accessible via signed URL. Files with a positive scan are quarantined to the `quarantine/` bucket and the uploader is notified. |
| Prevention | PDF JavaScript stripping     | PDFs are re-rendered via `pdfcpu` or `qpdf --linearize --decrypt` with JavaScript stripped before they are served. The original is kept for forensic purposes in a non-user-accessible bucket.                 |
| Prevention | Signed URL gating            | A file cannot be downloaded via signed URL until its `documents.scan_status = 'clean'`. `scan_status IN ('pending', 'scanning', 'quarantined')` return 409 with a retry-after hint.                            |
| Prevention | Content-Disposition response | Served files set `Content-Disposition: attachment` (not inline) unless MIME is explicitly `image/*` — prevents browser-side auto-render of PDFs with embedded scripts.                                         |
| Detection  | Scan outcome metrics         | `file_scan_outcome` counter (clean / infected / quarantined) exported to Grafana. Spike in `infected` count triggers alert `malicious_upload_surge` (P1, see RB-15-adjacent).                                    |
| Response   | Automatic notify + isolate   | On `infected` verdict: uploader's account is rate-limited for 24h, admin is notified, any doctor or admin that previously fetched a signed URL for the file is notified for endpoint scanning.                 |

**Schema impact:** add `scan_status VARCHAR(20) DEFAULT 'pending'` and `scan_result JSONB` columns to `documents`. See veridian_schema.sql.

**Residual risk after controls:** Low

---

#### D-4: Search Endpoint Abuse — Expensive Semantic Query Flooding

**Boundary:** 1, 3  
**Actor:** Competitor, automated attacker  
**Attack:** Attacker floods `GET /doctors` with complex free-text `query` parameters, each triggering an OpenAI embedding API call and a pgvector ANN search. Each request costs money and CPU time.

**Likelihood:** Medium  
**Impact:** Medium — OpenAI API cost, search latency for legitimate users

**Controls:**

| Layer      | Control                    | Implementation                                                                                                                                                                          |
| ---------- | -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Semantic search rate limit | Requests with a non-empty `query` parameter (semantic search path) are rate-limited to 20 per IP per minute. Requests without `query` (SQL-only path) have a higher limit of 60/minute. |
| Prevention | Embedding cache            | Query embeddings are cached in Redis with a 5-minute TTL. Identical or near-identical queries reuse the cached embedding without calling OpenAI.                                        |
| Prevention | Feature flag               | Semantic search is controlled by the `semantic_search_enabled` feature flag. Can be disabled instantly if costs spike, falling back to SQL search.                                      |
| Prevention | Query length limit         | `query` parameter max length is 500 characters. Longer queries are truncated and a warning is returned.                                                                                 |
| Prevention | Cloudflare rate limiting   | Cloudflare rate limits before requests reach the origin server. Bot-scored traffic gets tighter limits.                                                                                 |

**Residual risk after controls:** Low

---

### ELEVATION OF PRIVILEGE THREATS

---

#### E-1: Patient Accessing Doctor Endpoints

**Boundary:** 3  
**Actor:** Malicious patient  
**Attack:** Patient calls `POST /appointments/{id}/complete`, `POST /admin/doctors/{id}/verify`, or other doctor/admin-only endpoints.

**Likelihood:** Low  
**Impact:** Medium — fraudulent completion (triggers payout), unauthorized KYC approvals

**Controls:**

| Layer      | Control                 | Implementation                                                                                                                                                                                        |
| ---------- | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Role permission class   | Every view has explicit `permission_classes`. Doctor-only views use `IsDoctor`. Admin views use `IsPlatformAdmin`. Role is embedded in the JWT claim at issuance and cannot be changed by the client. |
| Prevention | Role claim immutability | `role` is a server-set field on the `users` table. No endpoint allows a user to change their own role. Only `platform_admin` can change another user's role via the Django admin panel.               |
| Prevention | Role re-read with Redis cache | On every authenticated request, the DRF auth middleware looks up the user's `role` from a Redis cache (key `user_role:{user_id}`, 60-second TTL). On cache miss, one row lookup against `users`. When `platform_admin` changes any user's role, the service explicitly deletes the cache key (`role_cache.bust(user_id)`) and adds a `jti` to the refresh-token blocklist so the next auth picks up the new role. Stale-JWT privilege is capped at 60 seconds; DB load per request stays near zero under steady state. |
| Prevention | Defence in depth        | Role check in JWT → Role re-read (cached) → DRF permission class → Object-level ownership check in service layer. Four independent checks before any privileged action executes.                       |

**Residual risk after controls:** Very Low

---

#### E-2: Clinic Admin Over-Reach — Accessing Other Clinics' Data

**Boundary:** 3  
**Actor:** Malicious clinic admin  
**Attack:** Clinic admin for Clinic A calls `GET /appointments?clinic_id={clinic_b_id}` or `PATCH /clinics/{clinic_b_id}` to access or modify a competitor clinic's data.

**Likelihood:** Low  
**Impact:** Medium — data exposure, unauthorized modification

**Controls:**

| Layer      | Control                 | Implementation                                                                                                                                                 |
| ---------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | Clinic membership check | All clinic admin actions verify that `request.user` is a registered admin for the specific clinic being accessed. Checked against `clinic_affiliations` table. |
| Prevention | Filtered querysets      | The `appointments` queryset for clinic admins is filtered to `clinic_affiliation.clinic_id IN user_clinic_ids` before any additional filters are applied.      |
| Prevention | Object-level permission | `PATCH /clinics/{id}` checks `clinic.created_by == request.user` OR `user has admin role for this clinic`.                                                     |

**Residual risk after controls:** Very Low

---

#### E-3: Privilege Escalation via JWT Claim Manipulation

**Boundary:** 3  
**Actor:** Any authenticated user  
**Attack:** User attempts to modify the JWT payload (e.g. change `role` from `patient` to `platform_admin`) before sending it to the API.

**Likelihood:** Very Low (requires breaking HS256 HMAC or RS256 signature without the key)  
**Impact:** Critical — full admin access

**Controls:**

| Layer      | Control                    | Implementation                                                                                                                                                                                       |
| ---------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | JWT signature verification | All JWTs are verified using `django-rest-framework-simplejwt`. Signature validation occurs before any claim is read. Modified payload = invalid signature = 401.                                     |
| Prevention | Algorithm hardening        | JWT algorithm is `RS256` (asymmetric). The private key signs tokens; the public key verifies them. Even if the signing key leaks from one component, the verification key alone cannot forge tokens. |
| Prevention | `alg: none` rejection      | SimpleJWT is configured to reject JWTs with `alg: none`. This prevents the classic "none algorithm" attack.                                                                                          |
| Prevention | Role from database         | On each request, the role is re-read from the `users` table, not trusted solely from the JWT claim. Even a manipulated JWT role claim is overridden by the database value.                           |

**Residual risk after controls:** Very Low

---

#### E-4: Mass Assignment — Forcing Unintended Field Updates

**Boundary:** 3  
**Actor:** Any user  
**Attack:** User sends unexpected fields in a PATCH request body (e.g. `{ "verification_status": "verified", "role": "platform_admin" }`) hoping the API blindly assigns all incoming fields to the model.

**Likelihood:** Low-Medium (common vulnerability in Django if serializers are misused)  
**Impact:** High — privilege escalation, bypassing KYC

**Controls:**

| Layer      | Control                                   | Implementation                                                                                                                                         |
| ---------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Prevention | Explicit serializer fields                | All DRF serializers use explicit `fields = [...]` or `read_only_fields = [...]`. No serializer uses `fields = '__all__'`.                              |
| Prevention | Read-only critical fields                 | `verification_status`, `role`, `is_active`, `created_at`, `doctor_profile_id`, `patient_id` are `read_only=True` on all serializers that include them. |
| Prevention | Separate request and response serializers | Request serializers accept only writable user-controlled fields. Response serializers expose server-computed fields. They are never the same class.    |
| Prevention | Code review gate                          | PRs that add `fields = '__all__'` to any serializer are automatically rejected by a pre-commit hook.                                                   |

**Residual risk after controls:** Very Low

---

#### E-5: Platform Admin Account Takeover

**Boundary:** 3
**Actor:** External attacker with credentials (phishing, leaked password, reused SSO)
**Attack:** Attacker compromises a `platform_admin` account via SIM swap + OTP, credential stuffing, or a malicious browser extension. Once authenticated as platform_admin, the attacker can suspend doctors, approve fake KYC, read the `audit_log`, issue refunds, or change arbitrary users' roles — essentially total system compromise.

**Likelihood:** Medium — platform_admin is a small set of humans, but compromise blast radius is catastrophic and the attacker only needs one.
**Impact:** Critical — total platform compromise, PHI exposure, financial loss.

**Controls:**

| Layer      | Control                      | Implementation                                                                                                                                                                                                                    |
| ---------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Prevention | WebAuthn / hardware key MFA  | Every `platform_admin` account MUST have at least one WebAuthn credential registered (YubiKey, Apple Passkey, or Android Passkey). OTP alone is NOT sufficient. Attempting to log in as platform_admin without WebAuthn returns 403. |
| Prevention | No OTP-only login for admins | Django settings gate: `if user.role == 'platform_admin' and not user.has_webauthn_credential(): raise PermissionDenied`. OTP is allowed as a second factor, never the sole factor.                                                  |
| Prevention | IP allowlist (optional)      | Platform admin login is restricted to known office IPs or VPN CIDR ranges. Configurable via `PLATFORM_ADMIN_IP_ALLOWLIST` env var. Failed attempts outside the allowlist trigger alert `admin_login_off_network`.                    |
| Prevention | Short-lived admin sessions   | Platform admin JWTs have access TTL 5 minutes (vs 15 min for patient/doctor). Refresh token TTL 8 hours (vs 30 days). Forces frequent re-auth.                                                                                     |
| Prevention | No API key fallback          | There is no "admin API key" that bypasses WebAuthn. Service-to-service actions use the Supabase service role key only.                                                                                                              |
| Detection  | Role anomaly                 | Alert `admin_access_anomaly` (P0, see RB-12) fires on: (a) platform_admin login from a new device, (b) platform_admin issuing > 20 mutations in 60 seconds, (c) any new platform_admin role assignment.                            |
| Detection  | Second-person review         | Destructive admin actions (mass refund > 50 users, role change to platform_admin, mass doctor suspension > 10) require a second platform_admin to approve within 15 minutes. Implemented as a queued action in admin_portal.       |

**Residual risk after controls:** Low

---

## Penetration Testing Scope

The following areas must be explicitly tested before production launch and after any major API change:

### P1: Authentication & Session Management

- OTP brute force (6-digit: 10^6 possibilities; rate limiting must block at attempt 3)
- JWT `alg: none` attack
- JWT role claim manipulation
- Refresh token replay after rotation
- Concurrent session handling (two devices)

### P2: Broken Object-Level Authorisation (BOLA)

- Access another patient's appointments via UUID
- Access another patient's health timeline
- Modify another doctor's availability templates
- Block another doctor's slots
- Complete another doctor's appointment

### P3: Broken Function-Level Authorisation (BFLA)

- Patient calling doctor-only endpoints
- Patient calling admin endpoints
- Doctor calling admin endpoints
- Clinic admin accessing other clinics

### P4: Injection

- SQL injection via all query parameters (specialization_slug, city, query, etc.)
- JSONB injection via pre-consultation responses
- Path traversal in file storage keys
- ReDoS via form template pattern field

### P5: Payment Security

- Modify `amount` in booking request body
- Replay a Paystack webhook reference
- Forge a Paystack webhook (without HMAC)
- Double-confirm an appointment (concurrent verify requests)

### P6: Business Logic

- Book a slot that is `reserved` (race condition)
- Book with an inactive/unverified doctor
- Reschedule to a slot belonging to a different doctor
- Submit a review for an appointment in `requested` status (not completed)
- Submit two reviews for the same appointment

### P7: Rate Limiting

- OTP flooding (phone number enumeration)
- Booking endpoint flooding
- Semantic search flooding
- File upload size bypass

---

## Security Headers (Web — Next.js)

```typescript
// next.config.ts
const securityHeaders = [
  { key: "X-DNS-Prefetch-Control", value: "on" },
  {
    key: "Strict-Transport-Security",
    value: "max-age=63072000; includeSubDomains; preload",
  },
  { key: "X-Frame-Options", value: "SAMEORIGIN" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  {
    key: "Permissions-Policy",
    value: "camera=(), microphone=(), geolocation=(self)",
  },
  {
    key: "Content-Security-Policy",
    value: [
      "default-src 'self'",
      "script-src 'self'", // No unsafe-inline, no unsafe-eval
      "style-src 'self' 'unsafe-inline'", // Tailwind requires inline styles
      "img-src 'self' data: https://*.supabase.co",
      "font-src 'self'",
      "connect-src 'self' https://api.Veridian.app https://*.supabase.co https://*.daily.co",
      "frame-src https://*.daily.co", // Telehealth iframe
      "frame-ancestors 'none'",
    ].join("; "),
  },
];
```

---

## Sensitive Data Classification

| Data                    | Classification      | At-rest protection                                     | In-transit protection | Retention                                                     |
| ----------------------- | ------------------- | ------------------------------------------------------ | --------------------- | ------------------------------------------------------------- |
| Health timeline content | Critical PHI        | AES-256 encrypted (app level)                          | TLS 1.2+              | Anonymised after account deletion; retained 7 years for legal |
| Diagnosis notes         | Critical PHI        | AES-256 encrypted (app level)                          | TLS 1.2+              | Same as above                                                 |
| Bank account numbers    | Sensitive financial | AES-256 encrypted (app level)                          | TLS 1.2+              | Deleted on account deletion                                   |
| JWT private key         | Critical secret     | Railway environment variable (never in code)           | N/A                   | Rotated every 90 days                                         |
| Paystack secret key     | Critical secret     | Railway environment variable                           | N/A                   | Rotated on suspected compromise                               |
| OTP codes               | Transient secret    | Redis only, 300s TTL                                   | TLS                   | Auto-expired                                                  |
| Patient phone numbers   | PII                 | Postgres (standard encryption at rest via Supabase)    | TLS                   | Anonymised after account deletion                             |
| Appointment details     | Sensitive           | Postgres (standard)                                    | TLS                   | 7 years (legal)                                               |
| Audit log               | Sensitive           | Postgres (standard)                                    | TLS                   | 7 years (legal); append-only                                  |
| Doctor license scans    | Sensitive           | Supabase Storage (private bucket, AES-256 by Supabase) | TLS                   | Until doctor account deletion                                 |

---

## Key Rotation Schedule

| Secret                    | Rotation frequency | Trigger for immediate rotation        |
| ------------------------- | ------------------ | ------------------------------------- |
| JWT RS256 private key     | Every 90 days      | Any suspected key exposure            |
| Paystack secret key       | Every 180 days     | Any webhook signature failure pattern |
| Supabase service role key | Every 180 days     | Any unauthorized access detection     |
| Termii API key            | Every 180 days     | OTP flooding detection                |
| OpenAI API key            | Every 90 days      | Cost anomaly detection                |
| Redis auth password       | Every 180 days     | Infrastructure access change          |
| Django `SECRET_KEY`       | Every 90 days      | Any suspected exposure                |

**Rotation procedure:** All secrets are Railway environment variables. Rotation steps: (1) Generate new secret in provider dashboard. (2) Add new secret to Railway alongside old one (dual-key period). (3) Deploy. (4) Verify new secret is active. (5) Remove old secret from Railway. (6) Revoke old secret in provider dashboard. (7) Update this document with rotation date.

---

## Incident Response Matrix

| Incident                       | Severity | Immediate action                                         | Within 1 hour                                                        | Within 24 hours                                                                  |
| ------------------------------ | -------- | -------------------------------------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Health record breach confirmed | P0       | Isolate affected DB tables; revoke all sessions          | Notify platform admin; begin forensics; notify affected patients     | Notify Ghana Data Protection Commission (DPC) within 72 hours as required by law |
| Payment credential exposed     | P0       | Rotate Paystack key immediately; pause all payments      | Audit transactions since exposure; notify Paystack                   | Notify affected patients of potential exposure                                   |
| Account takeover confirmed     | P1       | Revoke all sessions for affected account; lock account   | Notify affected user via email; begin investigation                  | Restore legitimate access after identity re-verification                         |
| Double-booking occurred        | P1       | Manually contact both patients; offer priority rebooking | Identify root cause (race condition escaped? DB constraint failure?) | Fix + deploy patch; notify both patients with compensation                       |
| DDoS in progress               | P2       | Enable Cloudflare "Under Attack" mode                    | Identify attack pattern; tighten rate limits                         | Post-mortem                                                                      |
| Fake doctor profile discovered | P1       | Immediately suspend profile                              | Notify all patients who booked; offer free rebooking                 | Law enforcement referral if fraud confirmed                                      |
| Data export (GDPR request)     | P3       | Acknowledge within 24 hours                              | Queue export job                                                     | Deliver export within 30 days                                                    |

---

## Appendix A — Supabase Direct-Read Table Inventory

Flutter and Next.js clients read a **defined subset** of tables directly via the Supabase client library (REST + Realtime), bypassing Django entirely. For these tables, **Supabase RLS is the sole authorisation layer** — Django permission classes, DRF serializers, and service-layer checks do not run.

This appendix is the **canonical inventory**. Any table not listed here must not be read directly by clients. Any new table added to this list requires a matching RLS test in `veridian-test-strategy.md` before merge.

| Table / View             | Read by              | Purpose                                    | RLS policy                                      |
| ------------------------ | -------------------- | ------------------------------------------ | ----------------------------------------------- |
| `slots`                  | anon + authenticated | Slot grid, realtime availability           | `slots_public_read`                             |
| `doctor_profiles`        | anon + authenticated | Search results, profile pages              | `doctor_profile_public_read`                    |
| `doctor_specializations` | anon + authenticated | Search filters                             | piggybacks on doctor_profile_public_read        |
| `doctor_languages`       | anon + authenticated | Search filters                             | piggybacks on doctor_profile_public_read        |
| `clinic_affiliations`    | anon + authenticated | Doctor → clinic join                       | piggybacks on doctor_profile_public_read        |
| `clinics`                | anon + authenticated | Clinic info                                | public (no RLS, all verified clinics visible)   |
| `reviews`                | anon + authenticated | Review list on doctor profile              | `reviews_public_read`                           |
| `v_appointments_safe`    | authenticated        | Appointments list + detail (URL-gated)     | view inherits base RLS on `appointments`        |
| `health_timeline_entries`| authenticated        | Patient timeline, doctor consented read    | `timeline_patient_own`, `timeline_doctor_consent_read` |
| `consent_grants`         | authenticated        | Consent management UI                      | `consent_patient_own`, `consent_doctor_read`    |
| `consent_terms_acceptances` | authenticated     | Consent history for DPA SAR                | `cta_own_read`                                  |
| `saved_doctors`          | authenticated        | Offline-synced favourites                  | `saved_doctors_own`                             |
| `notification_preferences` | authenticated      | Notification settings UI                   | `notif_prefs_own`                               |
| `bank_accounts`          | authenticated        | Payout setup UI (doctor)                   | `bank_accounts_own`                             |

**NOT direct-read (Django-only):**

- `appointments` (raw table — clients must use `v_appointments_safe`)
- `payment_transactions`, `payouts` (financial, DRF endpoint only)
- `audit_log`, `refresh_token_blocklist` (internal)
- `doctor_profiles.profile_embedding` (VECTOR column — expose via search endpoint only)
- `users` (exposed only through DRF `/me` and the doctor profile join)

**CI gate:** `scripts/check_direct_read_inventory.py` runs on every PR that touches `clients/flutter/**` or `clients/web/src/lib/supabase/**`. It greps for every `supabase.from('<table>')` call and fails the build if the table is not in the appendix above.

---

\*Next document: **Document 7 of 10 — Test Strategy\***  
_Unit, integration, end-to-end, and performance testing across Django, Flutter, and Next.js — coverage targets, test data strategy, CI integration, and the non-negotiable test gates before every production deployment._

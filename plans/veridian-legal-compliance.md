# Veridian — Document 9 of 10: Legal & Compliance (Ghana)

**Project:** Veridian All-in-One Service Booking Platform  
**Version:** 1.0.0  
**Status:** Authoritative — all legal obligations, consent flows, data retention policies, and regulatory registrations derive from this document  
**Classification:** Sensitive — engineering, legal, and executive personnel only  
**Disclaimer:** This document reflects the best available understanding of Ghanaian law as of 2025. It is not a substitute for qualified legal advice. Veridian must engage a Ghanaian legal practitioner before launch and review this document annually or whenever relevant legislation changes.

---

## Regulatory Landscape Summary

Veridian operates at the intersection of four regulatory domains in Ghana:

| Domain                    | Primary legislation / body                                       | Veridian's obligation                                                    |
| ------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Data protection           | Data Protection Act, 2012 (Act 843) / Data Protection Commission | Registration, lawful processing, consent, breach notification            |
| Digital health            | Ministry of Health / Ghana Health Service (GHS)                  | No specific digital health platform law exists yet; GHS guidelines apply |
| Medical professionals     | Medical and Dental Council Act, 1996 (Act 526) / GMDC            | Verification of licensed practitioners before listing                    |
| Electronic transactions   | Electronic Transactions Act, 2008 (Act 772)                      | Electronic contracts, records, and signatures are valid                  |
| Payments                  | Payment Systems and Services Act, 2019 (Act 987) / Bank of Ghana | Paystack holds the relevant licence; Veridian uses Paystack as agent     |
| Telecommunications        | Electronic Communications Act, 2008 (Act 775) / NCA              | SMS OTP delivery via Termii                                              |
| Consumer protection       | Consumer Protection Agency Act, 2023 (Act 1074)                  | Clear terms, refund rights, fair trading                                 |
| National health insurance | National Health Insurance Act, 2012 (Act 852) / NHIA             | No direct obligation at launch; future integration consideration         |

---

## Part 1: Data Protection Act 2012 (Act 843)

### 1.1 Overview

The Data Protection Act 2012 (DPA) is Ghana's primary data privacy law. It applies to any organisation that processes personal data in Ghana or processes data of Ghanaian data subjects. Veridian processes highly sensitive personal data — health information — which receives heightened protection under the Act.

The Act establishes:

- The Data Protection Commission (DPC) as the regulatory body
- Registration obligations for data controllers
- Eight data protection principles
- Data subject rights
- Obligations for sensitive personal data (which includes health data)
- Breach notification requirements

### 1.2 Registration with the Data Protection Commission

**Obligation:** Every data controller must register with the DPC before processing personal data (Section 17, DPA 2012).

**What Veridian must do:**

1. Register as a data controller at https://www.dataprotection.org.gh before the platform processes any real patient data.
2. The registration identifies the data controller (the Veridian company entity), the categories of data processed, the purposes of processing, and the security measures in place.
3. Registration must be renewed annually.
4. A **Data Protection Officer (DPO)** must be designated. At Veridian's early stage, this can be a named senior employee (e.g. the CTO) rather than a dedicated hire.

**Registration fee:** Approximately GHS 500–2,000 depending on organisation size (verify current fee schedule with DPC).

**Consequence of non-registration:** Fine of up to GHS 300,000 and/or imprisonment of officers.

### 1.3 The Eight Data Protection Principles

The DPA requires that personal data is processed in accordance with eight principles. Veridian's compliance obligations for each:

**Principle 1 — Accountability**  
The data controller is responsible for compliance. Veridian must maintain records of all processing activities, appoint a DPO, and be able to demonstrate compliance to the DPC on request.

_Implementation:_ Maintain a Record of Processing Activities (ROPA) document. This is a living document listing every category of personal data, the purpose of processing, the legal basis, retention period, and security measures. See Section 1.7 below for the Veridian ROPA.

**Principle 2 — Lawfulness of processing**  
Personal data must be processed on a lawful basis. For sensitive data (health information), the bar is higher — explicit consent is the primary lawful basis.

_Implementation:_ See Section 1.4 (Consent Framework).

**Principle 3 — Specification of purpose**  
Data must be collected for a specific, explicit, and legitimate purpose and not processed in a manner incompatible with that purpose.

_Implementation:_

- At registration, patients are told exactly why their data is collected: "to connect you with healthcare providers, manage your appointments, and maintain your health records."
- Veridian must not use health timeline data for advertising, profiling for non-health purposes, or sale to third parties.
- Using anonymised, aggregated data for platform analytics (e.g. "most-searched specializations in Accra") is permissible — it is not personal data after proper anonymisation.

**Principle 4 — Compatibility of further processing**  
Any subsequent use of data must be compatible with the original purpose.

_Implementation:_ If Veridian later wants to use patient data for AI model training, this requires separate explicit consent — it is not compatible with the original appointment-booking purpose.

**Principle 5 — Quality of data**  
Data must be accurate, complete, and kept up to date.

_Implementation:_ Patients can update their profile at any time. The platform proactively prompts annual review of health profile data (allergies, chronic conditions, medications).

**Principle 6 — Openness**  
Data subjects must be informed about how their data is processed.

_Implementation:_ Privacy Notice (see Section 1.5) must be presented at registration and available at all times in the app. Any change to the privacy notice requires re-notification and, where the change affects consent-based processing, re-consent.

**Principle 7 — Data security safeguards**  
Appropriate technical and organisational measures must be taken to protect data.

_Implementation:_ See Document 6 (Security Threat Model). Key measures: AES-256 encryption of health records at application level, TLS 1.2+ in transit, access controls via RLS, JWT-based authentication, audit logging.

**Principle 8 — Data subject participation**  
Data subjects have the right to know what data is held about them and to request correction or deletion.

_Implementation:_ See Section 1.6 (Data Subject Rights).

### 1.4 Consent Framework

Health data is **sensitive personal data** under the DPA. Processing requires **explicit, informed consent** (Section 24, DPA 2012). The consent must be:

- **Freely given** — not a condition of accessing the service where the service could reasonably be provided without that data
- **Specific** — for each distinct purpose
- **Informed** — the data subject understands what they are consenting to
- **Unambiguous** — affirmative action (not pre-ticked boxes)
- **Withdrawable** — the data subject can withdraw consent at any time without detriment

**Veridian consent architecture:**

| Consent type             | When obtained                                  | What it covers                                        | Can be withdrawn?                     |
| ------------------------ | ---------------------------------------------- | ----------------------------------------------------- | ------------------------------------- |
| Registration consent     | At account creation                            | Collection of name, phone, role                       | Yes — account deletion                |
| Health profile consent   | When patient first adds health data            | Storage of blood group, allergies, chronic conditions | Yes — delete health profile           |
| Health timeline consent  | When first timeline entry is created           | Storage and processing of health records              | Yes — deletes all entries             |
| Doctor access consent    | Explicit grant before doctor can view timeline | Doctor X reading patient's health timeline            | Yes — revoke at any time via Settings |
| Marketing communications | Optional, at registration                      | Newsletters, promotions (NOT health data)             | Yes — unsubscribe                     |
| Analytics consent        | Optional, at registration                      | Usage analytics (anonymised)                          | Yes — opt out in Settings             |

**Consent must NOT be bundled.** The patient must be able to accept appointment booking without accepting marketing emails. Each consent is a separate affirmative action.

**Consent record storage:**

Two distinct consent tables live in the schema — do not confuse them:

| Table                         | Purpose                                                                                              | Lifecycle                                                          |
| ----------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `consent_terms_acceptances`   | DPA-mandated record of each user's consent to terms/privacy/marketing/analytics                       | One row per user per `consent_type` per privacy-notice version     |
| `consent_grants` (see Doc 1)  | Patient → doctor access grants for health timeline, prescriptions, lab results                        | Revocable at any time via Settings; required before doctor reads   |

```sql
-- consent_terms_acceptances table (add to schema — distinct from consent_grants)
CREATE TABLE consent_terms_acceptances (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    consent_type    VARCHAR(100) NOT NULL,   -- 'terms_of_service' | 'privacy_notice' |
                                             -- 'health_profile' | 'health_timeline' |
                                             -- 'marketing' | 'analytics'
    version         VARCHAR(20) NOT NULL,    -- Privacy notice version e.g. '1.2'
    granted         BOOLEAN NOT NULL,
    granted_at      TIMESTAMPTZ,
    withdrawn_at    TIMESTAMPTZ,
    ip_address      INET,
    user_agent      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (user_id, consent_type, version)
);

CREATE INDEX idx_cta_user_type ON consent_terms_acceptances(user_id, consent_type)
    WHERE withdrawn_at IS NULL;
```

Every consent grant and withdrawal is recorded with timestamp and the version of the privacy notice in effect at the time. This is the evidence of consent required by the DPC. `consent_grants` (doctor access) is audit-logged separately and already present in the canonical schema (veridian_schema.sql).

**Consent UI requirements (Flutter and Next.js):**

```
□ Consent checkboxes are unchecked by default
□ The label adjacent to each checkbox clearly states what is being consented to
□ A link to the full privacy notice is visible on the consent screen
□ Consenting to one item does not imply consent to others
□ The "Create account" button is disabled until mandatory consents are checked
□ Mandatory vs optional consents are visually distinguished
□ Consent for health data is presented separately from registration consent
```

### 1.5 Privacy Notice Requirements

The Privacy Notice (also called Privacy Policy) must be available in-app, written in plain language accessible to a Ghanaian patient with a secondary education. Key required contents under the DPA:

1. **Identity of the data controller** — Full legal name of the Veridian company, registered address in Ghana, contact email and phone.

2. **Data Protection Officer contact** — Name and email of the designated DPO.

3. **Categories of personal data collected** — Explicit list: name, phone number, date of birth, health profile (blood group, allergies, etc.), health timeline entries (symptoms, diagnoses, prescriptions), appointment history, payment transaction references (not full card details — never stored).

4. **Purposes of processing** — Bullet-by-bullet: booking appointments, matching patients with doctors, storing health records for continuity of care, processing payments, sending appointment reminders.

5. **Legal basis for each purpose** — For health data: explicit consent. For appointment reminders: legitimate interest (patient safety) or consent. For fraud prevention: legitimate interest.

6. **Who data is shared with** — List all third parties: Paystack (payment processing), Termii (SMS delivery), Daily.co (telehealth video), Railway (cloud hosting, data processor), Supabase (database, data processor), Sentry (error monitoring, may contain metadata). Each processor must have a Data Processing Agreement (DPA) in place with Veridian.

7. **International transfers** — Railway, Supabase, and Daily.co process data outside Ghana. The DPA 2012 requires that data transferred outside Ghana is protected to equivalent standards. Veridian must include contractual safeguards (standard contractual clauses or equivalent) in contracts with these processors.

8. **Retention periods** — See Section 1.7 (Retention Policy).

9. **Data subject rights** — Explanation of all rights in Section 1.6.

10. **How to withdraw consent** — Clear instructions: "You can withdraw consent at any time by going to Settings → Privacy → Manage Consent."

11. **Complaints process** — "If you believe your data rights have been violated, you may contact the Data Protection Commission of Ghana at www.dataprotection.org.gh."

**Privacy Notice must be:**

- Available in English (Twi version strongly recommended for accessibility)
- Versioned (include a version number and effective date)
- Updated whenever Veridian's data practices change
- Re-presented to existing users when materially updated

### 1.6 Data Subject Rights

Under the DPA 2012, every data subject has the following rights. Veridian must implement mechanisms to exercise each:

| Right                        | Description                                | Veridian implementation                                            | Response time            |
| ---------------------------- | ------------------------------------------ | ------------------------------------------------------------------ | ------------------------ |
| Right to information         | Know what data is held                     | Privacy notice + `POST /users/me/export-data`                      | Available always         |
| Right of access              | Receive a copy of all personal data        | `POST /users/me/export-data` delivers a JSON/PDF archive           | 30 days (target: 7 days) |
| Right to rectification       | Correct inaccurate data                    | `PATCH /users/me`, patient profile update                          | Immediate                |
| Right to erasure             | Delete personal data                       | `POST /users/me/delete-account` (30-day grace, then anonymisation) | 30 days                  |
| Right to object              | Object to processing for specific purposes | Consent withdrawal in Settings                                     | Immediate                |
| Right to restrict processing | Limit how data is used                     | Account deactivation (`is_active = false`) without deletion        | Immediate                |

**Health record erasure — special rule:**  
The DPA right to erasure applies to health records. However, there is a competing obligation: health records may need to be retained for medical-legal reasons (see Section 1.7). Veridian's approach: on deletion request, health record **content is anonymised** (the encrypted content is replaced with a marker indicating deletion, patient_id is replaced with a pseudonym), but the record's existence, date, and type are retained for audit purposes. The doctor-authored entries are retained in full for the legal retention period — the patient is informed of this at the time of the deletion request.

### 1.7 Record of Processing Activities (ROPA) and Retention Policy

**Retention schedule:**

| Data category                                       | Retention period                             | Basis                                       | Action at end of period               |
| --------------------------------------------------- | -------------------------------------------- | ------------------------------------------- | ------------------------------------- |
| User account data (name, phone, email)              | Duration of account + 30 days after deletion | Contractual                                 | Hard delete after 30-day grace        |
| Appointment records (non-health)                    | 7 years from appointment date                | Legal — medical liability limitation period | Hard delete                           |
| Health timeline entries (patient-authored)          | 7 years from creation                        | Legal — medical records retention           | Anonymise (remove patient_id linkage) |
| Health timeline entries (doctor-authored diagnoses) | 10 years from creation                       | Medical-legal standard practice             | Anonymise                             |
| Payment transaction records                         | 7 years from transaction                     | Financial regulations (ICAG guidelines)     | Hard delete                           |
| Audit log                                           | 7 years                                      | Legal evidence                              | Archive to cold storage               |
| Consent records                                     | Duration of account + 7 years                | DPA compliance evidence                     | Archive                               |
| SMS/notification logs                               | 90 days                                      | Operational                                 | Hard delete                           |
| Error logs (Sentry)                                 | 90 days                                      | Operational                                 | Auto-purge                            |
| JWT refresh token blocklist                         | Until token expiry                           | Security                                    | Auto-purge by cron                    |
| Doctor KYC documents                                | Duration of listing + 5 years after removal  | Regulatory / fraud evidence                 | Archive to cold storage               |

**Automated enforcement:**

```python
# management/commands/enforce_retention_policy.py
# Runs as a monthly Celery Beat task

class RetentionEnforcementTask:
    def run(self):
        self._delete_inactive_accounts()        # > 30 days post-deletion-request
        self._anonymise_old_health_records()    # > 7/10 years
        self._purge_old_payment_records()       # > 7 years
        self._archive_old_audit_logs()          # > 7 years → cold storage
        self._purge_expired_notification_logs() # > 90 days
```

### 1.8 Data Breach Notification

Under the DPA 2012 (Section 35), Veridian must notify the Data Protection Commission of a data breach **within 72 hours** of becoming aware of it.

The notification must include:

1. Nature of the breach (what happened)
2. Categories and approximate number of data subjects affected
3. Categories and approximate number of records affected
4. Likely consequences of the breach
5. Measures taken or proposed to address the breach

Affected data subjects must be notified **without undue delay** if the breach is likely to result in high risk to their rights and freedoms.

_Note: The DPA 2012 predates GDPR; the 72-hour requirement is modelled on emerging best practice in Ghana and should be confirmed with a Ghanaian lawyer as this area of law is actively evolving._

**See Runbook RB-15 for the operational breach response procedure.**

### 1.9 Data Processing Agreements (DPAs) with Third Parties

The following third-party processors must have a signed Data Processing Agreement with Veridian before going live. The DPA must confirm the processor only processes data on Veridian's instructions and implements appropriate security measures.

| Processor         | Role                      | Data shared                                   | DPA status                                                                              |
| ----------------- | ------------------------- | --------------------------------------------- | --------------------------------------------------------------------------------------- |
| Supabase          | Database and storage host | All personal data                             | Standard DPA available at supabase.com/dpa — must be signed                             |
| Railway           | Application hosting       | May contain personal data in logs             | Standard DPA — review and sign                                                          |
| Paystack          | Payment processing        | Patient name, phone, transaction amounts      | Paystack's standard merchant agreement includes data processing terms                   |
| Termii            | SMS delivery              | Patient phone number, OTP content             | Review Termii's privacy terms — obtain DPA if not included                              |
| Daily.co          | Telehealth video          | Patient and doctor video/audio during session | Daily.co DPA available — must be signed                                                 |
| Sentry            | Error monitoring          | May contain metadata, no deliberate PHI       | Sentry DPA available — sign and configure data scrubbing to avoid PHI in error payloads |
| OpenAI            | Embedding generation      | Doctor profile text only (no patient data)    | OpenAI API data processing addendum — sign                                              |
| Google (Firebase) | Push notifications        | Device tokens, notification content           | Firebase DPA — sign                                                                     |

---

## Part 2: Ghana Health Service and Medical Council Requirements

### 2.1 Digital Health Platform Status in Ghana

As of 2025, Ghana does not have a specific law regulating digital health platforms or telemedicine as a distinct category. Veridian operates in this regulatory gap under the following framework:

- **Veridian is a booking intermediary, not a healthcare provider.** It does not diagnose, prescribe, or provide medical advice. It facilitates appointments between patients and licensed doctors. This distinction is important — it means Veridian does not require a healthcare facility license from the GHS.

- **Doctors using Veridian are individually licensed.** The Medical and Dental Council Act 1996 (Act 526) requires all medical practitioners to be registered with the Ghana Medical and Dental Council (GMDC). Veridian's KYC process (Document 1, Document 3) verifies GMDC registration before any doctor is listed.

- **The Ministry of Health has issued digital health guidelines** ("Ghana Digital Health Strategic Framework") which encourage digital health initiatives but do not impose specific licensing on booking platforms.

### 2.2 Doctor Verification Obligations

Veridian's legal obligation: **verify that every listed doctor holds a current, valid GMDC licence before they can accept bookings.** Listing an unregistered practitioner and facilitating patient contact creates legal risk (aiding unlicensed medical practice, potential liability for patient harm).

**Verification process:**

1. Doctor submits their GMDC licence number and uploads their licence card scan during KYC.
2. Platform admin verifies the licence number against the GMDC online registry (https://gmdc.org.gh/verify) or by calling the GMDC verification line.
3. Admin confirms that the licence is:
   - Valid (not expired)
   - In good standing (not suspended or revoked)
   - Belongs to the person applying (photo matches, name matches)
4. Admin approves the profile. Doctor goes live.

**Annual re-verification:** GMDC licences are renewed annually. Veridian must:

- Store the `license_expiry_date` on the doctor profile
- Send a reminder to the doctor 60 days before expiry: "Your GMDC licence expires on [date]. Please upload your renewed licence to remain listed."
- Automatically **deactivate** the profile (not delete — deactivate) if the licence is not renewed within 14 days of expiry
- Notify patients with pending appointments if a doctor is deactivated: see RB-07

**Specialization accuracy:** Doctors must only list specializations they are qualified in. False specialization claims are a professional misconduct issue with the GMDC. Veridian's terms of service must require doctors to only list accurate specializations, with platform right to remove misrepresented listings.

### 2.3 Telehealth Regulatory Status

**Current position (2025):** Ghana does not have a specific Telemedicine Act. The Ghana Telemedicine Policy (2018) provides a framework but is a policy document, not binding legislation.

Key provisions of the Ghana Telemedicine Policy relevant to Veridian:

1. **Telehealth is recognized as legitimate healthcare delivery.** Telemedicine is explicitly supported by the Ministry of Health as a mechanism to extend healthcare access, particularly to underserved communities.

2. **The doctor-patient relationship.** The policy expects that telemedicine should build on an existing doctor-patient relationship where possible. For first consultations via telehealth, doctors should exercise clinical judgment about whether a remote consultation is appropriate.

3. **Prescribing.** Electronic prescriptions issued during telehealth consultations are valid in Ghana, provided they meet the requirements of the Food and Drugs Authority (FDA) regarding prescription format, and the doctor is appropriately licensed.

4. **Clinical responsibility.** The consulting doctor retains full clinical and professional responsibility for the advice given via telehealth. Veridian has no clinical responsibility. Veridian's liability is limited to the platform functionality (correct slot delivery, accurate doctor information).

**Veridian platform obligations for telehealth:**

- The telehealth functionality must display a disclaimer: "This consultation is a remote medical consultation. For emergencies, please call 193 (ambulance) or visit your nearest hospital emergency department."
- Veridian must not allow telehealth bookings for categories of care that the Ministry of Health explicitly restricts to in-person settings (e.g. controlled substance prescriptions — while not currently explicitly regulated digitally in Ghana, Veridian should prohibit listing these as telehealth-appropriate specializations).
- Telehealth session recordings: Daily.co sessions should NOT be recorded by default. If a doctor or patient wishes to record, both must explicitly consent and Veridian must handle the recording as health data under Part 1.

### 2.4 GHS Notification (Recommended, Not Mandatory)

While not legally required, it is strongly recommended that Veridian:

1. **Register with the Ghana Health Service as a digital health partner.** The GHS maintains a registry of approved digital health tools. Registration signals legitimacy and opens doors to potential integration with public health systems (e.g. Expanded Programme on Immunisation data, NHIS verification).

2. **Engage the GHS Digital Health Division** during the platform build phase. The GHS can provide guidance on data standards (e.g. HL7 FHIR compatibility for health records — consider adopting this format for health timeline exports) and alert Veridian to upcoming regulatory changes.

3. **Align with the Ghana eHealth Architecture** (Ministry of Health, 2020). This architecture document sets standards for interoperability between health systems in Ghana. Adopting its standards now reduces future technical debt if Veridian integrates with public health infrastructure.

---

## Part 3: Payment Regulation

### 3.1 Paystack Licensing

Veridian uses Paystack as its primary payment processor. Paystack holds a **Payment Service Provider licence** from the Bank of Ghana under the Payment Systems and Services Act 2019 (Act 987).

**Veridian's obligations under this arrangement:**

- Veridian is a **merchant** on Paystack's platform, not a payment service provider itself. Veridian does not hold, manage, or transit funds directly. Paystack handles all payment processing and holds the required BoG licence.
- Veridian must complete Paystack's **KYB (Know Your Business)** process, which includes: company registration documents, directors' identification, bank account details, and a description of the business model.
- **Paystack's acceptable use policy** prohibits certain business categories. Veridian (healthcare booking) is a permitted use. However, any later expansion (e.g. pharmaceutical sales) would need to be reviewed against Paystack's policy.

### 3.2 Transaction Records

The Payment Systems and Services Act 2019 requires payment records to be retained. The Bank of Ghana has issued guidelines requiring financial transaction records to be kept for at least **5 years** (some sources indicate 7 years aligns with international best practice). Veridian's retention policy (Section 1.7) uses 7 years for payment records — this satisfies both the local requirement and international standard.

### 3.3 Foreign Currency Transactions

Veridian starts with GHS only. If international patients book consultations (e.g. diaspora Ghanaians booking for family members in Ghana), Stripe handles international cards. Any foreign currency revenue must be disclosed in Veridian's corporate tax filings. The Ghana Revenue Authority (GRA) requires foreign-currency income to be reported.

### 3.4 Doctor Payouts

Weekly payouts to doctors via Paystack Transfer are subject to:

- **Withholding Tax:** Payments to doctors for professional services are subject to 15% withholding tax under the Income Tax Act 2015 (Act 896), unless the doctor provides a valid withholding tax exemption certificate. Veridian must deduct and remit this tax to the GRA.
- **SSNIT contributions:** If Veridian classifies doctors as employees rather than independent contractors, SSNIT contributions would apply. Veridian's model treats doctors as independent service providers — this should be explicitly stated in the Doctor Service Agreement and should be reviewed by a Ghanaian tax lawyer.
- **Monthly tax remittance:** Veridian must remit collected withholding tax to the GRA by the 15th of the following month.

**Implementation:**

```python
# payouts/services.py
# Values are read from platform_settings so that a GRA rate change does
# not require a code deploy. Stored in basis points on each payout row
# (payouts.tax_rate_bps) so historical payouts remain reconstructable.
DEFAULT_DOCTOR_WITHHOLDING_TAX_BPS = 1500  # 15.00% — Income Tax Act 2015

def calculate_payout(gross_amount: int, has_tax_exemption: bool) -> dict:
    platform_fee = int(gross_amount * Decimal('0.08'))  # 8% platform fee
    gross_after_fee = gross_amount - platform_fee
    rate_bps = 0 if has_tax_exemption else settings.DOCTOR_WITHHOLDING_TAX_BPS
    tax_withheld_minor = int(gross_after_fee * rate_bps // 10_000)
    net_amount = gross_after_fee - tax_withheld_minor
    return {
        'gross_amount': gross_amount,
        'platform_fee': platform_fee,
        'tax_withheld_minor': tax_withheld_minor,  # maps 1:1 to payouts.tax_withheld_minor
        'tax_rate_bps': rate_bps,                   # stored on payouts.tax_rate_bps
        'net_amount': net_amount,
    }
```

A monthly Celery beat task `payouts.generate_wht_remittance_report` aggregates `SUM(tax_withheld_minor)` by period and produces the GRA remittance file by the 13th of each month (2-day buffer before the 15th deadline).

---

## Part 4: Electronic Transactions Act 2008 (Act 772)

### 4.1 Electronic Contracts

Bookings made on Veridian are electronic contracts. The Electronic Transactions Act 2008 validates electronic contracts in Ghana. Key provisions:

- **An appointment booking is a binding contract** between the patient and the doctor/clinic. The booking confirmation email/notification constitutes the offer and acceptance.
- **Electronic signatures** (including OTP-verified account actions) are valid under Act 772.
- **The platform terms of service** form a contract between Veridian and each user (patient, doctor, clinic admin). These must be accepted at registration — not buried in a footer link.

### 4.2 Electronic Records

The Act validates electronic records as admissible evidence. Veridian's audit log, appointment records, and payment transaction records are all valid electronic records that can be used as evidence in dispute resolution.

### 4.3 Terms of Service Requirements

Veridian's Terms of Service must include:

**For patients:**

- Scope of service (booking intermediary — not a healthcare provider)
- Patient responsibilities (providing accurate health information, attending booked appointments)
- Cancellation and refund policy (specific timeframes and amounts — these must match what is implemented in the code per Document 3)
- Dispute resolution process
- Limitation of liability (Veridian is not liable for medical advice given by doctors)
- Jurisdiction and governing law (Ghana)

**For doctors:**

- Service provider relationship (independent contractor, not Veridian employee)
- Obligation to maintain valid GMDC licence and notify Veridian of any changes
- Prohibited conduct (misrepresentation of qualifications, no-shows, fraudulent consultations)
- Platform fee structure (8% of consultation fee — must be explicitly disclosed)
- Data access limitations (can only access patient data for booked patients)
- Consequences of violation (suspension, account termination)
- Withholding tax acknowledgment (doctor acknowledges that Veridian will deduct and remit 15% WHT)

**Both:**

- Privacy notice reference and consent
- Acceptable use policy
- Intellectual property (Veridian owns the platform; users own their personal data)

---

## Part 5: Consumer Protection

### 5.1 Consumer Protection Agency Act 2023 (Act 1074)

The Consumer Protection Agency Act 2023 establishes consumer rights in Ghana. Relevant to Veridian:

**Right to accurate information:** Doctor profiles must be accurate. Misleading profiles (false qualifications, doctored photos) violate this right. Veridian's KYC process and post-listing monitoring are the compliance mechanisms.

**Right to fair terms:** Cancellation and refund policies must be fair and clearly disclosed before booking. Veridian's tiered refund policy (full refund > 24h, partial within window, none < 2h) must be presented to the patient in plain language at Step 3 of the booking flow (review screen) — not just in the terms of service.

**Right to redress:** Patients must have an accessible complaints process. Veridian must provide:

- In-app complaint filing (flag a doctor, report an issue)
- Response within 3 business days
- Escalation path if not resolved

**Price transparency:** The consultation fee must be displayed before booking is completed. No hidden fees. Platform service fees embedded in the doctor's displayed fee are acceptable; undisclosed additional charges at checkout are not.

### 5.2 Refund Policy Disclosure

The refund policy must be written in plain Ghanaian English and displayed:

1. On the doctor's profile page (before the patient selects a slot)
2. On the review screen (Step 3 of booking, before payment)
3. In the booking confirmation email

Example plain-language disclosure:

> "Cancellation policy: Free cancellation up to 24 hours before your appointment. Cancellations within 24 hours may receive a partial refund based on the clinic's policy. Cancellations within 2 hours of the appointment may not receive a refund. If your doctor cancels, you will always receive a full refund."

---

## Part 6: National Health Insurance Scheme (NHIS)

### 6.1 Current Position

Veridian does not integrate with the National Health Insurance Scheme at launch. Most private consultations facilitated by Veridian will be out-of-pocket ("cash pay") or covered by private insurance.

### 6.2 Future NHIS Integration Considerations

The National Health Insurance Act 2012 (Act 852) governs the NHIA. Key points for future integration:

- **NHIA accreditation:** To process NHIS claims, a provider must be accredited by the NHIA. Individual doctors on Veridian may or may not be NHIA-accredited. Veridian could add an "NHIS accepted" filter to the doctor search in a future phase.
- **NHIS claim submission:** Processing NHIS claims requires integration with the NHIA's claims management system. This is a Phase 3+ consideration.
- **Community-Based Health Planning and Services (CHPS):** Veridian could partner with CHPS compounds to digitise their appointment systems — a social impact opportunity and potential GHS partnership channel.

---

## Part 7: Specific Platform Obligations Summary

This section consolidates the "must do before launch" obligations.

### Pre-Launch Legal Checklist

```
COMPANY AND REGISTRATION
□ Veridian incorporated as a legal entity in Ghana (GH company limited by shares or guarantee)
□ Registered with the Registrar-General's Department
□ Tax Identification Number (TIN) obtained from GRA
□ Paystack KYB process completed and merchant account approved
□ Bank account opened in the company name

DATA PROTECTION
□ Registered with the Data Protection Commission (Act 843)
□ Data Protection Officer designated and named in privacy notice
□ Data Processing Agreements signed with all third-party processors (Supabase, Railway,
  Termii, Daily.co, Paystack, Google Firebase, OpenAI, Sentry)
□ Privacy Notice drafted in plain English and reviewed by a lawyer
□ Twi version of privacy notice available (strongly recommended)
□ Consent mechanisms implemented per Section 1.4 (unchecked boxes, separate consents)
□ Consent records table implemented and recording all grant/withdrawal events
□ Data subject rights endpoints operational (export, delete, rectify)
□ Retention policy implemented in code (monthly enforcement task)
□ Breach notification procedure documented (RB-15) and tested

MEDICAL PROFESSIONAL VERIFICATION
□ GMDC verification process documented and admin team trained
□ Licence expiry monitoring implemented (automated deactivation + reminder emails)
□ Doctor Service Agreement reviewed by a Ghanaian lawyer
□ Terms of Service reviewed by a Ghanaian lawyer

PAYMENTS AND TAX
□ 15% withholding tax deduction implemented in payout calculations
□ WHT remittance process to GRA documented (15th of following month)
□ Doctor tax exemption certificate upload mechanism available
□ Monthly WHT reconciliation report available for finance team

CONSUMER PROTECTION
□ Cancellation and refund policy displayed at booking review step (Step 3)
□ Consultation fee displayed prominently on doctor profile page
□ In-app complaint/reporting mechanism functional
□ Customer support response SLA defined (3 business days)

LEGAL DOCUMENTS (all must be reviewed by a Ghanaian lawyer before launch)
□ Privacy Notice / Privacy Policy
□ Terms of Service (patient-facing)
□ Doctor Service Agreement (doctor-facing)
□ Clinic Partner Agreement (clinic admin-facing)
□ Cookie Policy (web only)
□ Telehealth disclaimer (displayed in video consultation UI)
□ Cancellation and Refund Policy (standalone, also referenced in ToS)
```

### Ongoing Compliance Obligations (Post-Launch)

| Obligation                                          | Frequency                         | Owner                    |
| --------------------------------------------------- | --------------------------------- | ------------------------ |
| DPC registration renewal                            | Annual                            | Legal / Operations       |
| GMDC licence re-verification for all active doctors | Annual (triggered by expiry date) | Platform (automated)     |
| Privacy notice review and update                    | Annual or on significant change   | Legal / Engineering      |
| WHT remittance to GRA                               | Monthly (by 15th)                 | Finance                  |
| DPC breach notification (if applicable)             | Within 72 hours of breach         | Engineering / Legal      |
| Consumer Protection Agency complaint response       | Within 3 business days            | Customer Support         |
| Paystack merchant account review                    | Annual (Paystack-initiated)       | Operations               |
| Retention policy enforcement task                   | Monthly (automated)               | Engineering (monitoring) |
| Data subject access request fulfilment              | Within 30 days of request         | Engineering / Operations |
| Legal landscape review (new legislation)            | Annual                            | Legal                    |

---

## Part 8: Disclaimers and Limitations of This Document

1. **This is not legal advice.** This document provides an engineering and operational framework for compliance but does not substitute for advice from a qualified Ghanaian lawyer. Veridian must engage a Ghanaian legal practitioner (ideally with experience in technology, data protection, and healthcare) before going live.

2. **Legislation is evolving.** Ghana's digital health and data protection regulatory landscape is actively developing. The Electronic Transactions Act and Data Protection Act are both relatively established, but telehealth regulation, digital health platform licensing, and health data portability rules may change. This document must be reviewed annually.

3. **This document covers Ghana only.** If Veridian later expands to other African markets (Nigeria, Kenya, Côte d'Ivoire), separate compliance assessments are required for each jurisdiction.

4. **Tax guidance requires a tax specialist.** The withholding tax section reflects the general framework under the Income Tax Act 2015 but rates and exemptions are subject to annual Finance Act amendments. Engage a Ghanaian chartered accountant for current rates before implementing payout calculations.

---

\*Next document: **Document 10 of 10 — UI/UX Wireframes\***  
_Low-fidelity wireframes for all critical user journeys: patient onboarding, doctor discovery, booking flow, appointment management, health timeline, doctor dashboard, and the dark forest-green design system application across Flutter mobile (light/dark) and Next.js web (light only)._

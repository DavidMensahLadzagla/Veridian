"""Health records vertical (Layer 5, PHI): patient profiles, encrypted timeline entries,
consent (terms acceptances + doctor grants), documents.

Enums are TextChoices + CHECK (ADR-0006). Timeline entry content is AES-256-GCM ciphertext held
in BYTEA (content_encrypted/content_iv); key_version records which master-key version sealed the
row so the RB-05 rotation job can run online and resumably. These tables are REVOKEd from direct
client SELECT (ADR-0003) — reads go through the API service layer, never Supabase Realtime.
"""

from __future__ import annotations

from django.contrib.postgres.fields import ArrayField
from django.db import models

from core.models import CreatedModel, SoftDeleteModel, TimestampedModel


class TimelineEntryType(models.TextChoices):
    SYMPTOM_LOG = "symptom_log", "Symptom log"
    DIAGNOSIS_NOTE = "diagnosis_note", "Diagnosis note"
    PRESCRIPTION = "prescription", "Prescription"
    LAB_RESULT = "lab_result", "Lab result"
    PATIENT_NOTE = "patient_note", "Patient note"
    VACCINATION = "vaccination", "Vaccination"
    ALLERGY_RECORD = "allergy_record", "Allergy record"


class TimelineVisibility(models.TextChoices):
    PATIENT_ONLY = "patient_only", "Patient only"
    SHARED_WITH_CURRENT_DOCTOR = "shared_with_current_doctor", "Shared with current doctor"
    SHARED_WITH_ALL_FUTURE_DOCTORS = (
        "shared_with_all_future_doctors",
        "Shared with all future doctors",
    )


class ConsentScope(models.TextChoices):
    READ_TIMELINE = "read_timeline", "Read timeline"
    READ_PRESCRIPTIONS = "read_prescriptions", "Read prescriptions"
    READ_LAB_RESULTS = "read_lab_results", "Read lab results"
    READ_ALL = "read_all", "Read all"


class ConsentTermsType(models.TextChoices):
    TERMS_OF_SERVICE = "terms_of_service", "Terms of service"
    PRIVACY_NOTICE = "privacy_notice", "Privacy notice"
    HEALTH_PROFILE = "health_profile", "Health profile"
    HEALTH_TIMELINE = "health_timeline", "Health timeline"
    MARKETING = "marketing", "Marketing"
    ANALYTICS = "analytics", "Analytics"


class DocumentType(models.TextChoices):
    MEDICAL_LICENSE = "medical_license", "Medical license"
    NATIONAL_ID = "national_id", "National ID"
    PROOF_OF_ADDRESS = "proof_of_address", "Proof of address"
    QUALIFICATION_CERTIFICATE = "qualification_certificate", "Qualification certificate"
    LAB_RESULT = "lab_result", "Lab result"
    PRESCRIPTION = "prescription", "Prescription"
    INSURANCE_CARD = "insurance_card", "Insurance card"
    OTHER = "other", "Other"


class ScanStatus(models.TextChoices):
    PENDING = "pending", "Pending"
    CLEAN = "clean", "Clean"
    INFECTED = "infected", "Infected"
    ERROR = "error", "Error"


class PatientProfile(TimestampedModel):
    user = models.OneToOneField("identity.User", on_delete=models.CASCADE, db_column="user_id")
    blood_group = models.CharField(max_length=5, null=True, blank=True)
    genotype = models.CharField(max_length=5, null=True, blank=True)
    height_cm = models.DecimalField(max_digits=5, decimal_places=1, null=True, blank=True)
    weight_kg = models.DecimalField(max_digits=5, decimal_places=1, null=True, blank=True)
    allergies = ArrayField(models.TextField(), null=True, blank=True)
    chronic_conditions = ArrayField(models.TextField(), null=True, blank=True)
    emergency_contact_name = models.CharField(max_length=200, null=True, blank=True)
    emergency_contact_phone = models.CharField(max_length=20, null=True, blank=True)
    emergency_contact_relation = models.CharField(max_length=100, null=True, blank=True)
    insurance_provider = models.CharField(max_length=200, null=True, blank=True)
    insurance_number = models.CharField(max_length=100, null=True, blank=True)
    # Per-patient key material: HKDF(HEALTH_RECORD_MASTER_KEY, salt=patient_key_salt).
    # Salt generated once at creation (DB default gen_random_bytes(32) via RunSQL).
    patient_key_salt = models.BinaryField(max_length=32, null=True, blank=True)

    class Meta:
        db_table = "patient_profiles"

    def __str__(self) -> str:
        return f"PatientProfile<{self.user_id}>"


class HealthTimelineEntry(SoftDeleteModel):
    """Encrypted at rest. content_encrypted/content_iv are AES-256-GCM ciphertext + nonce."""

    patient = models.ForeignKey("identity.User", on_delete=models.RESTRICT, db_column="patient_id")
    appointment = models.ForeignKey(
        "appointments.Appointment",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="appointment_id",
    )
    authored_by = models.ForeignKey(
        "identity.User",
        on_delete=models.RESTRICT,
        db_column="authored_by",
        related_name="+",
    )
    entry_type = models.CharField(max_length=20, choices=TimelineEntryType.choices)
    title = models.CharField(max_length=500, null=True, blank=True)
    content_encrypted = models.BinaryField()  # AES-256-GCM ciphertext of JSONB payload
    content_iv = models.BinaryField()  # random 96-bit GCM nonce, unique per entry
    key_version = models.SmallIntegerField(default=1)
    visibility = models.CharField(
        max_length=40,
        choices=TimelineVisibility.choices,
        default=TimelineVisibility.PATIENT_ONLY,
    )
    attachment_keys = ArrayField(models.TextField(), default=list)
    icd10_codes = ArrayField(models.CharField(max_length=10), null=True, blank=True)
    is_pinned = models.BooleanField(default=False)

    class Meta:
        db_table = "health_timeline_entries"
        indexes = [
            models.Index(fields=["patient", "-created_at"], name="idx_timeline_patient"),
        ]


class ConsentTermsAcceptance(CreatedModel):
    """DPA 2012 consent evidence. NOT the same as ConsentGrant (doctor timeline access)."""

    user = models.ForeignKey("identity.User", on_delete=models.CASCADE, db_column="user_id")
    consent_type = models.CharField(max_length=100, choices=ConsentTermsType.choices)
    version = models.CharField(max_length=20)
    granted = models.BooleanField()
    granted_at = models.DateTimeField(null=True, blank=True)
    withdrawn_at = models.DateTimeField(null=True, blank=True)
    ip_address = models.GenericIPAddressField(null=True, blank=True)
    user_agent = models.TextField(null=True, blank=True)

    class Meta:
        db_table = "consent_terms_acceptances"
        constraints = [
            models.UniqueConstraint(
                fields=["user", "consent_type", "version"], name="uq_consent_terms"
            ),
        ]


class ConsentGrant(TimestampedModel):
    """Patient → doctor consent to read the patient's timeline."""

    patient = models.ForeignKey("identity.User", on_delete=models.CASCADE, db_column="patient_id")
    granted_to_doctor = models.ForeignKey(
        "doctors.DoctorProfile", on_delete=models.CASCADE, db_column="granted_to_doctor"
    )
    scope = models.CharField(
        max_length=20, choices=ConsentScope.choices, default=ConsentScope.READ_TIMELINE
    )
    granted_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField(null=True, blank=True)
    revoked_at = models.DateTimeField(null=True, blank=True)
    revoke_reason = models.TextField(null=True, blank=True)

    class Meta:
        db_table = "consent_grants"
        constraints = [
            models.UniqueConstraint(
                fields=["patient", "granted_to_doctor", "scope"], name="uq_consent_grant"
            ),
        ]


class Document(SoftDeleteModel):
    owner = models.ForeignKey("identity.User", on_delete=models.CASCADE, db_column="owner_id")
    document_type = models.CharField(max_length=30, choices=DocumentType.choices)
    storage_key = models.TextField()
    file_name = models.CharField(max_length=500, null=True, blank=True)
    mime_type = models.CharField(max_length=100, null=True, blank=True)
    file_size_bytes = models.IntegerField(null=True, blank=True)
    is_verified = models.BooleanField(default=False)
    verified_by = models.ForeignKey(
        "identity.User",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="verified_by",
        related_name="+",
    )
    verified_at = models.DateTimeField(null=True, blank=True)
    rejection_reason = models.TextField(null=True, blank=True)
    expires_at = models.DateTimeField(null=True, blank=True)
    # Malware scan: uploads land in quarantine with scan_status='pending'; signed URLs are
    # only issued when scan_status='clean'.
    scan_status = models.CharField(
        max_length=20, choices=ScanStatus.choices, default=ScanStatus.PENDING
    )
    scan_result = models.JSONField(null=True, blank=True)
    scanned_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "documents"
        indexes = [
            models.Index(fields=["owner", "document_type"], name="idx_doc_owner_type"),
        ]

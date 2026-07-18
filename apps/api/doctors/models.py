"""Doctor vertical (Layer 4): specializations, clinics, doctor profiles, availability, slots.

Enums are TextChoices + CHECK (ADR-0006). Slots carry both the local wall-clock (slot_date/
start_time, for display + uniqueness) and absolute instants start_at/end_at (ADR-0004) that all
time math uses.
"""

from __future__ import annotations

from django.contrib.gis.db import models as gis_models
from django.contrib.postgres.fields import ArrayField
from django.db import models
from django.db.models import F, Q
from pgvector.django import VectorField

from core.models import CreatedModel, SoftDeleteModel, TimestampedModel


class VerificationStatus(models.TextChoices):
    UNVERIFIED = "unverified", "Unverified"
    PENDING_REVIEW = "pending_review", "Pending review"
    VERIFIED = "verified", "Verified"
    REJECTED = "rejected", "Rejected"
    SUSPENDED = "suspended", "Suspended"


class BookingMode(models.TextChoices):
    IN_PERSON = "in_person", "In person"
    TELEHEALTH = "telehealth", "Telehealth"
    EITHER = "either", "Either"


class DayOfWeek(models.TextChoices):
    MONDAY = "monday", "Monday"
    TUESDAY = "tuesday", "Tuesday"
    WEDNESDAY = "wednesday", "Wednesday"
    THURSDAY = "thursday", "Thursday"
    FRIDAY = "friday", "Friday"
    SATURDAY = "saturday", "Saturday"
    SUNDAY = "sunday", "Sunday"


class SlotStatus(models.TextChoices):
    AVAILABLE = "available", "Available"
    RESERVED = "reserved", "Reserved"
    BOOKED = "booked", "Booked"
    BLOCKED = "blocked", "Blocked"
    EXPIRED = "expired", "Expired"


class Specialization(TimestampedModel):
    name = models.CharField(max_length=200, unique=True)
    slug = models.CharField(max_length=200, unique=True)
    parent = models.ForeignKey(
        "self", null=True, blank=True, on_delete=models.RESTRICT, db_column="parent_id"
    )
    description = models.TextField(null=True, blank=True)
    is_active = models.BooleanField(default=True)
    sort_order = models.SmallIntegerField(default=0)

    class Meta:
        db_table = "specializations"

    def __str__(self) -> str:
        return self.name


class Clinic(SoftDeleteModel):
    name = models.CharField(max_length=300)
    slug = models.CharField(max_length=300, unique=True)
    description = models.TextField(null=True, blank=True)
    address_line1 = models.CharField(max_length=300, null=True, blank=True)
    address_line2 = models.CharField(max_length=300, null=True, blank=True)
    city = models.CharField(max_length=100, null=True, blank=True)
    region = models.CharField(max_length=100, null=True, blank=True)
    country_code = models.CharField(max_length=2, default="GH")
    timezone = models.CharField(max_length=60, default="Africa/Accra")  # IANA (ADR-0004)
    postal_code = models.CharField(max_length=20, null=True, blank=True)
    location = gis_models.PointField(geography=True, srid=4326, null=True, blank=True)
    phone = models.CharField(max_length=20, null=True, blank=True)
    email = models.EmailField(max_length=320, null=True, blank=True)
    website = models.CharField(max_length=500, null=True, blank=True)
    logo_storage_key = models.TextField(null=True, blank=True)
    photos_storage_keys = ArrayField(models.TextField(), default=list)
    is_active = models.BooleanField(default=True)
    verification_status = models.CharField(
        max_length=20, choices=VerificationStatus.choices, default=VerificationStatus.UNVERIFIED
    )
    created_by = models.ForeignKey(
        "identity.User", null=True, blank=True, on_delete=models.SET_NULL, db_column="created_by"
    )

    class Meta:
        db_table = "clinics"
        indexes = [gis_models.Index(fields=["location"], name="idx_clinics_location")]

    def __str__(self) -> str:
        return self.name


class DoctorProfile(TimestampedModel):
    user = models.OneToOneField("identity.User", on_delete=models.CASCADE, db_column="user_id")
    bio = models.TextField(null=True, blank=True)
    years_of_experience = models.SmallIntegerField(null=True, blank=True)
    license_number = models.CharField(max_length=100, null=True, blank=True)
    license_issuing_council = models.CharField(max_length=200, null=True, blank=True)
    license_expiry_date = models.DateField(null=True, blank=True)
    license_storage_key = models.TextField(null=True, blank=True)
    verification_status = models.CharField(
        max_length=20, choices=VerificationStatus.choices, default=VerificationStatus.UNVERIFIED
    )
    verified_at = models.DateTimeField(null=True, blank=True)
    verified_by = models.ForeignKey(
        "identity.User",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="verified_by",
        related_name="+",
    )
    rejection_reason = models.TextField(null=True, blank=True)
    rating_avg = models.DecimalField(max_digits=3, decimal_places=2, default=0)
    rating_count = models.IntegerField(default=0)
    rating_punctuality_avg = models.DecimalField(max_digits=3, decimal_places=2, default=0)
    rating_communication_avg = models.DecimalField(max_digits=3, decimal_places=2, default=0)
    rating_medical_avg = models.DecimalField(max_digits=3, decimal_places=2, default=0)
    profile_completeness_pct = models.SmallIntegerField(default=0)
    response_rate_pct = models.SmallIntegerField(default=100)
    slot_confidence_score = models.DecimalField(max_digits=3, decimal_places=2, default=1)
    profile_views = models.IntegerField(default=0)
    accepts_new_patients = models.BooleanField(default=True)
    is_profile_active = models.BooleanField(default=True)
    profile_embedding = VectorField(dimensions=1536, null=True, blank=True)
    embedding_model = models.CharField(max_length=64, default="text-embedding-3-small")
    embedding_content_hash = models.CharField(max_length=64, null=True, blank=True)
    embedding_updated_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "doctor_profiles"
        constraints = [
            models.CheckConstraint(
                condition=Q(rating_avg__gte=0) & Q(rating_avg__lte=5), name="doctor_rating_range"
            ),
            models.CheckConstraint(
                condition=Q(slot_confidence_score__gte=0) & Q(slot_confidence_score__lte=1),
                name="doctor_confidence_range",
            ),
        ]

    def __str__(self) -> str:
        return f"Dr. {self.user.full_name} ({self.verification_status})"


class DoctorSpecialization(CreatedModel):
    doctor_profile = models.ForeignKey(
        DoctorProfile, on_delete=models.CASCADE, db_column="doctor_profile_id"
    )
    specialization = models.ForeignKey(
        Specialization, on_delete=models.RESTRICT, db_column="specialization_id"
    )
    is_primary = models.BooleanField(default=False)

    class Meta:
        db_table = "doctor_specializations"
        constraints = [
            models.UniqueConstraint(
                fields=["doctor_profile", "specialization"], name="uq_doctor_specialization"
            ),
        ]


class DoctorLanguage(CreatedModel):
    class Proficiency(models.TextChoices):
        BASIC = "basic", "Basic"
        CONVERSATIONAL = "conversational", "Conversational"
        FLUENT = "fluent", "Fluent"
        NATIVE = "native", "Native"

    doctor_profile = models.ForeignKey(
        DoctorProfile, on_delete=models.CASCADE, db_column="doctor_profile_id"
    )
    language_code = models.CharField(max_length=10)
    proficiency = models.CharField(
        max_length=20, choices=Proficiency.choices, default=Proficiency.FLUENT
    )

    class Meta:
        db_table = "doctor_languages"
        constraints = [
            models.UniqueConstraint(
                fields=["doctor_profile", "language_code"], name="uq_doctor_language"
            ),
        ]


class DoctorQualification(TimestampedModel):
    doctor_profile = models.ForeignKey(
        DoctorProfile, on_delete=models.CASCADE, db_column="doctor_profile_id"
    )
    degree = models.CharField(max_length=200)
    institution = models.CharField(max_length=300)
    country_code = models.CharField(max_length=2, default="GH")
    year_obtained = models.SmallIntegerField(null=True, blank=True)

    class Meta:
        db_table = "doctor_qualifications"


class ClinicAffiliation(TimestampedModel):
    doctor_profile = models.ForeignKey(
        DoctorProfile, on_delete=models.CASCADE, db_column="doctor_profile_id"
    )
    clinic = models.ForeignKey(Clinic, on_delete=models.CASCADE, db_column="clinic_id")
    consulting_room = models.CharField(max_length=100, null=True, blank=True)
    is_primary_clinic = models.BooleanField(default=False)
    consultation_fee = models.IntegerField()  # minor units
    currency_code = models.CharField(max_length=3, default="GHS")
    telehealth_fee = models.IntegerField(null=True, blank=True)
    cancellation_free_window_hours = models.SmallIntegerField(default=24)
    is_active = models.BooleanField(default=True)
    started_at = models.DateField(null=True, blank=True)
    ended_at = models.DateField(null=True, blank=True)

    class Meta:
        db_table = "clinic_affiliations"
        constraints = [
            models.UniqueConstraint(
                fields=["doctor_profile", "clinic"], name="uq_clinic_affiliation"
            ),
            models.CheckConstraint(
                condition=Q(cancellation_free_window_hours__gte=0)
                & Q(cancellation_free_window_hours__lte=168),
                name="affiliation_free_window_range",
            ),
        ]


class AvailabilityTemplate(TimestampedModel):
    doctor_profile = models.ForeignKey(
        DoctorProfile, on_delete=models.CASCADE, db_column="doctor_profile_id"
    )
    clinic_affiliation = models.ForeignKey(
        ClinicAffiliation,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="clinic_affiliation_id",
    )
    day_of_week = models.CharField(max_length=10, choices=DayOfWeek.choices)
    start_time = models.TimeField()
    end_time = models.TimeField()
    slot_duration_minutes = models.SmallIntegerField(default=30)
    booking_mode = models.CharField(
        max_length=20, choices=BookingMode.choices, default=BookingMode.EITHER
    )
    buffer_minutes = models.SmallIntegerField(default=0)
    max_patients_per_slot = models.SmallIntegerField(default=1)
    is_active = models.BooleanField(default=True)
    effective_from = models.DateField()
    effective_until = models.DateField(null=True, blank=True)

    class Meta:
        db_table = "availability_templates"
        constraints = [
            models.CheckConstraint(
                condition=Q(end_time__gt=F("start_time")), name="template_time_check"
            ),
            models.CheckConstraint(
                condition=Q(slot_duration_minutes__in=[15, 20, 30, 45, 60]),
                name="template_slot_duration",
            ),
        ]


class Slot(TimestampedModel):
    doctor_profile = models.ForeignKey(
        DoctorProfile, on_delete=models.CASCADE, db_column="doctor_profile_id"
    )
    clinic_affiliation = models.ForeignKey(
        ClinicAffiliation,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="clinic_affiliation_id",
    )
    template = models.ForeignKey(
        AvailabilityTemplate,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="template_id",
    )
    slot_date = models.DateField()  # local wall-clock (display, filtering, uniqueness)
    start_time = models.TimeField()
    end_time = models.TimeField()
    start_at = models.DateTimeField()  # absolute instant — all time math (ADR-0004)
    end_at = models.DateTimeField()
    booking_mode = models.CharField(max_length=20, choices=BookingMode.choices)
    status = models.CharField(
        max_length=20, choices=SlotStatus.choices, default=SlotStatus.AVAILABLE
    )
    confidence_score = models.DecimalField(max_digits=3, decimal_places=2, default=1)
    block_reason = models.TextField(null=True, blank=True)
    blocked_by = models.ForeignKey(
        "identity.User", null=True, blank=True, on_delete=models.SET_NULL, db_column="blocked_by"
    )
    blocked_at = models.DateTimeField(null=True, blank=True)
    reserved_at = models.DateTimeField(null=True, blank=True)
    reservation_expires_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "slots"
        indexes = [
            models.Index(fields=["slot_date", "status"], name="idx_slots_date_status"),
            models.Index(fields=["start_at"], name="idx_slots_start_at"),
        ]
        constraints = [
            models.UniqueConstraint(
                fields=["doctor_profile", "slot_date", "start_time"], name="uq_slot"
            ),
            models.CheckConstraint(
                condition=Q(end_time__gt=F("start_time")), name="slot_time_check"
            ),
            models.CheckConstraint(
                condition=Q(end_at__gt=F("start_at")), name="slot_instant_check"
            ),
        ]


class SavedDoctor(CreatedModel):
    patient = models.ForeignKey("identity.User", on_delete=models.CASCADE, db_column="patient_id")
    doctor_profile = models.ForeignKey(
        DoctorProfile, on_delete=models.CASCADE, db_column="doctor_profile_id"
    )

    class Meta:
        db_table = "saved_doctors"
        constraints = [
            models.UniqueConstraint(fields=["patient", "doctor_profile"], name="uq_saved_doctor"),
        ]

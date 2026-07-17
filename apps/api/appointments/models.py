"""Booking vertical (Layer 5): pre-consultation form templates, appointments, status history,
reviews, telehealth sessions.

Enums are TextChoices + CHECK (ADR-0006). The circular FK with payments (appointment ↔
payment_transaction) is expressed with string references both directions. Cross-app FKs use
string model refs with an explicit db_column so the generated columns match the canonical DDL.
"""

from __future__ import annotations

from django.db import models
from django.db.models import Q

from core.models import CreatedModel, SoftDeleteModel, TimestampedModel
from doctors.models import BookingMode


class AppointmentStatus(models.TextChoices):
    REQUESTED = "requested", "Requested"
    CONFIRMED = "confirmed", "Confirmed"
    IN_PROGRESS = "in_progress", "In progress"
    COMPLETED = "completed", "Completed"
    CANCELLED_BY_PATIENT = "cancelled_by_patient", "Cancelled by patient"
    CANCELLED_BY_DOCTOR = "cancelled_by_doctor", "Cancelled by doctor"
    CANCELLED_BY_PLATFORM = "cancelled_by_platform", "Cancelled by platform"
    NO_SHOW_PATIENT = "no_show_patient", "No-show (patient)"
    NO_SHOW_DOCTOR = "no_show_doctor", "No-show (doctor)"


class ReviewStatus(models.TextChoices):
    PENDING = "pending", "Pending"
    PUBLISHED = "published", "Published"
    FLAGGED = "flagged", "Flagged"
    REMOVED = "removed", "Removed"


class PreConsultationFormTemplate(TimestampedModel):
    doctor_profile = models.ForeignKey(
        "doctors.DoctorProfile", on_delete=models.CASCADE, db_column="doctor_profile_id"
    )
    name = models.CharField(max_length=200)
    description = models.TextField(null=True, blank=True)
    fields = models.JSONField(default=list)
    is_default = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    version = models.SmallIntegerField(default=1)

    class Meta:
        db_table = "pre_consultation_form_templates"

    def __str__(self) -> str:
        return f"{self.name} (v{self.version})"


class Appointment(SoftDeleteModel):
    slot = models.ForeignKey("doctors.Slot", on_delete=models.RESTRICT, db_column="slot_id")
    patient = models.ForeignKey("identity.User", on_delete=models.RESTRICT, db_column="patient_id")
    doctor_profile = models.ForeignKey(
        "doctors.DoctorProfile", on_delete=models.RESTRICT, db_column="doctor_profile_id"
    )
    clinic_affiliation = models.ForeignKey(
        "doctors.ClinicAffiliation",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="clinic_affiliation_id",
    )
    status = models.CharField(
        max_length=25, choices=AppointmentStatus.choices, default=AppointmentStatus.REQUESTED
    )
    booking_mode = models.CharField(max_length=20, choices=BookingMode.choices)
    # Financial
    consultation_fee = models.IntegerField()  # minor units
    currency_code = models.CharField(max_length=3, default="GHS")
    platform_fee_pct = models.DecimalField(max_digits=5, decimal_places=2, default=8)
    payment_transaction = models.ForeignKey(
        "payments.PaymentTransaction",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="payment_transaction_id",
        related_name="+",
    )
    # Pre-consultation
    form_template = models.ForeignKey(
        PreConsultationFormTemplate,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="form_template_id",
    )
    pre_consultation_responses = models.JSONField(default=dict)
    patient_notes = models.TextField(null=True, blank=True)
    # Timing
    estimated_wait_minutes = models.SmallIntegerField(default=0)
    actual_start_time = models.DateTimeField(null=True, blank=True)
    actual_end_time = models.DateTimeField(null=True, blank=True)
    # Telehealth
    telehealth_room_id = models.CharField(max_length=255, null=True, blank=True)
    telehealth_room_url = models.TextField(null=True, blank=True)
    telehealth_patient_url = models.TextField(null=True, blank=True)
    telehealth_room_expires_at = models.DateTimeField(null=True, blank=True)
    # Cancellation
    cancelled_at = models.DateTimeField(null=True, blank=True)
    cancellation_reason = models.TextField(null=True, blank=True)
    cancelled_by = models.ForeignKey(
        "identity.User",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="cancelled_by",
        related_name="+",
    )
    # No-show
    no_show_marked_at = models.DateTimeField(null=True, blank=True)
    no_show_marked_by = models.ForeignKey(
        "identity.User",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="no_show_marked_by",
        related_name="+",
    )
    # Follow-up
    follow_up_recommended = models.BooleanField(null=True, blank=True)
    follow_up_notes = models.TextField(null=True, blank=True)
    follow_up_appointment = models.ForeignKey(
        "self",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="follow_up_appointment_id",
        related_name="+",
    )

    class Meta:
        db_table = "appointments"
        indexes = [
            models.Index(fields=["patient", "-created_at"], name="idx_appt_patient"),
            models.Index(fields=["doctor_profile", "-created_at"], name="idx_appt_doctor"),
            models.Index(fields=["slot"], name="idx_appt_slot"),
            models.Index(fields=["status"], name="idx_appt_status"),
        ]
        constraints = [
            models.CheckConstraint(condition=Q(consultation_fee__gte=0), name="appt_fee_nonneg"),
        ]


class AppointmentStatusHistory(CreatedModel):
    """Immutable log of every status transition (append-only via trigger)."""

    appointment = models.ForeignKey(
        Appointment, on_delete=models.CASCADE, db_column="appointment_id"
    )
    from_status = models.CharField(
        max_length=25, choices=AppointmentStatus.choices, null=True, blank=True
    )
    to_status = models.CharField(max_length=25, choices=AppointmentStatus.choices)
    actor = models.ForeignKey(
        "identity.User", null=True, blank=True, on_delete=models.SET_NULL, db_column="actor_id"
    )
    reason = models.TextField(null=True, blank=True)
    metadata = models.JSONField(default=dict)

    class Meta:
        db_table = "appointment_status_history"
        indexes = [
            models.Index(fields=["appointment", "-created_at"], name="idx_appt_hist"),
        ]


class Review(SoftDeleteModel):
    appointment = models.OneToOneField(
        Appointment, on_delete=models.RESTRICT, db_column="appointment_id"
    )
    patient = models.ForeignKey("identity.User", on_delete=models.RESTRICT, db_column="patient_id")
    doctor_profile = models.ForeignKey(
        "doctors.DoctorProfile", on_delete=models.RESTRICT, db_column="doctor_profile_id"
    )
    rating_overall = models.SmallIntegerField()
    rating_punctuality = models.SmallIntegerField()
    rating_communication = models.SmallIntegerField()
    rating_medical = models.SmallIntegerField()
    review_text = models.TextField(null=True, blank=True)
    doctor_reply = models.TextField(null=True, blank=True)
    doctor_replied_at = models.DateTimeField(null=True, blank=True)
    status = models.CharField(
        max_length=20, choices=ReviewStatus.choices, default=ReviewStatus.PENDING
    )
    flag_reason = models.TextField(null=True, blank=True)
    is_anonymous = models.BooleanField(default=False)

    class Meta:
        db_table = "reviews"
        indexes = [
            models.Index(fields=["doctor_profile", "-created_at"], name="idx_review_doctor"),
        ]
        constraints = [
            models.CheckConstraint(
                condition=Q(rating_overall__gte=1) & Q(rating_overall__lte=5),
                name="review_overall_range",
            ),
            models.CheckConstraint(
                condition=Q(rating_punctuality__gte=1) & Q(rating_punctuality__lte=5),
                name="review_punctuality_range",
            ),
            models.CheckConstraint(
                condition=Q(rating_communication__gte=1) & Q(rating_communication__lte=5),
                name="review_communication_range",
            ),
            models.CheckConstraint(
                condition=Q(rating_medical__gte=1) & Q(rating_medical__lte=5),
                name="review_medical_range",
            ),
        ]


class TelehealthSession(TimestampedModel):
    appointment = models.OneToOneField(
        Appointment, on_delete=models.CASCADE, db_column="appointment_id"
    )
    provider = models.CharField(max_length=50, default="daily.co")
    room_name = models.CharField(max_length=255)
    room_url = models.TextField()
    doctor_joined_at = models.DateTimeField(null=True, blank=True)
    patient_joined_at = models.DateTimeField(null=True, blank=True)
    ended_at = models.DateTimeField(null=True, blank=True)
    duration_seconds = models.IntegerField(null=True, blank=True)
    quality_score = models.DecimalField(max_digits=3, decimal_places=2, null=True, blank=True)
    provider_session_id = models.CharField(max_length=255, null=True, blank=True)

    class Meta:
        db_table = "telehealth_sessions"

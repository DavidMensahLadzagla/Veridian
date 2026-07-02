"""Shared base models + Layer-1 platform tables (service categories, feature flags, audit log,
idempotency keys). Mirrors veridian_schema.sql. Enums are TextChoices + CHECK (ADR-0006);
RLS/triggers/hash-chain ship via RunSQL in migrations, not here.
"""

from __future__ import annotations

import uuid

from django.contrib.postgres.fields import ArrayField
from django.db import models
from django.utils import timezone


# --- Abstract base classes ----------------------------------------------------
class UUIDModel(models.Model):
    """UUID primary key only. Never expose sequential ints to clients."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)

    class Meta:
        abstract = True


class CreatedModel(UUIDModel):
    """UUID PK + created_at only — for append-only / join tables with no updated_at."""

    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        abstract = True


class TimestampedModel(UUIDModel):
    """UUID PK + auto-managed created_at/updated_at."""

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True


class SoftDeleteQuerySet(models.QuerySet):
    def alive(self) -> "SoftDeleteQuerySet":
        return self.filter(deleted_at__isnull=True)

    def soft_delete(self) -> int:
        return self.update(deleted_at=timezone.now())


class SoftDeleteManager(models.Manager):
    """Default manager hides soft-deleted rows; all_with_deleted() includes them."""

    def get_queryset(self) -> SoftDeleteQuerySet:
        return SoftDeleteQuerySet(self.model, using=self._db).filter(deleted_at__isnull=True)

    def all_with_deleted(self) -> SoftDeleteQuerySet:
        return SoftDeleteQuerySet(self.model, using=self._db)


class SoftDeleteModel(TimestampedModel):
    deleted_at = models.DateTimeField(null=True, blank=True, default=None)

    objects = SoftDeleteManager()
    all_objects = models.Manager()

    class Meta:
        abstract = True

    def soft_delete(self) -> None:
        self.deleted_at = timezone.now()
        self.save(update_fields=["deleted_at", "updated_at"])


# --- Layer 1: shared platform tables ------------------------------------------
class ServiceCategorySlug(models.TextChoices):
    MEDICAL = "medical", "Medical"
    BARBER = "barber", "Barber"
    MECHANIC = "mechanic", "Mechanic"


class ServiceCategory(TimestampedModel):
    slug = models.CharField(max_length=20, choices=ServiceCategorySlug.choices, unique=True)
    display_name = models.CharField(max_length=100)
    description = models.TextField(null=True, blank=True)
    icon_key = models.TextField(null=True, blank=True)
    is_active = models.BooleanField(default=False)
    sort_order = models.SmallIntegerField(default=0)

    class Meta:
        db_table = "service_categories"

    def __str__(self) -> str:
        return self.display_name


class FeatureFlag(TimestampedModel):
    key = models.CharField(max_length=100, unique=True)
    description = models.TextField(null=True, blank=True)
    is_enabled = models.BooleanField(default=False)
    rollout_pct = models.SmallIntegerField(default=0)
    allowed_roles = ArrayField(models.CharField(max_length=20), null=True, blank=True)
    metadata = models.JSONField(default=dict)

    class Meta:
        db_table = "feature_flags"
        constraints = [
            models.CheckConstraint(
                condition=models.Q(rollout_pct__gte=0) & models.Q(rollout_pct__lte=100),
                name="feature_flag_rollout_pct_range",
            ),
        ]

    def __str__(self) -> str:
        return self.key


class AuditAction(models.TextChoices):
    INSERT = "INSERT", "Insert"
    UPDATE = "UPDATE", "Update"
    DELETE = "DELETE", "Delete"


class AuditLog(models.Model):
    """Append-only. BIGSERIAL PK (internal only, never exposed). The hash chain
    (prev_row_hash/row_hash) and the no-update/no-delete guards are enforced by triggers
    installed via RunSQL — the service layer never sets the hash columns."""

    id = models.BigAutoField(primary_key=True)
    actor = models.ForeignKey(
        "identity.User", null=True, blank=True, on_delete=models.SET_NULL, db_column="actor_id"
    )
    table_name = models.CharField(max_length=100)
    record_id = models.UUIDField()
    action = models.CharField(max_length=10, choices=AuditAction.choices)
    before_state = models.JSONField(null=True, blank=True)
    after_state = models.JSONField(null=True, blank=True)
    ip_address = models.GenericIPAddressField(null=True, blank=True)
    user_agent = models.TextField(null=True, blank=True)
    prev_row_hash = models.BinaryField(null=True, blank=True)  # set by audit_log_chain() trigger
    row_hash = models.BinaryField(null=True, blank=True)  # DB column is NOT NULL via RunSQL
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "audit_log"
        indexes = [
            models.Index(fields=["table_name", "record_id", "-created_at"]),
            models.Index(fields=["actor", "-created_at"]),
        ]


class IdempotencyStatus(models.TextChoices):
    IN_PROGRESS = "in_progress", "In progress"
    COMPLETED = "completed", "Completed"


class IdempotencyKey(models.Model):
    """ADR-0002. Composite PK (key, user_id); Django-only (RLS denies clients)."""

    pk = models.CompositePrimaryKey("key", "user")
    key = models.UUIDField()
    user = models.ForeignKey(
        "identity.User", on_delete=models.CASCADE, db_column="user_id"
    )
    endpoint = models.CharField(max_length=100)
    request_hash = models.CharField(max_length=64)
    status = models.CharField(
        max_length=20, choices=IdempotencyStatus.choices, default=IdempotencyStatus.IN_PROGRESS
    )
    response_code = models.SmallIntegerField(null=True, blank=True)
    response_body = models.JSONField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    completed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "idempotency_keys"
        indexes = [models.Index(fields=["created_at"], name="idx_idem_gc")]

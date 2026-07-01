"""Shared base models. Every Veridian table inherits UUID PKs + timestamps; most also
support soft delete. These mirror the conventions in the canonical schema (veridian_schema.sql).
"""

from __future__ import annotations

import uuid

from django.db import models
from django.utils import timezone


class TimestampedModel(models.Model):
    """UUID primary key + auto-managed created_at/updated_at. Never expose sequential ints."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
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
    """Default manager hides soft-deleted rows; use all_with_deleted() to include them."""

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

"""Notification templates, delivery log, and per-user channel preferences (Layer 2)."""

from __future__ import annotations

from django.db import models

from core.models import TimestampedModel


class NotificationChannel(models.TextChoices):
    PUSH = "push", "Push"
    SMS = "sms", "SMS"
    EMAIL = "email", "Email"
    IN_APP = "in_app", "In-app"


class NotificationStatus(models.TextChoices):
    PENDING = "pending", "Pending"
    SENT = "sent", "Sent"
    DELIVERED = "delivered", "Delivered"
    FAILED = "failed", "Failed"


class NotificationTemplate(TimestampedModel):
    # NOTE: canonical SQL declares `key` inline-UNIQUE AND UNIQUE(key,channel,language) — the
    # inline one is a bug (it forbids multiple channels/languages per key). We keep only the
    # composite. Flag to reconcile veridian_schema.sql.
    key = models.CharField(max_length=100)
    channel = models.CharField(max_length=10, choices=NotificationChannel.choices)
    language = models.CharField(max_length=10, default="en")
    subject = models.TextField(null=True, blank=True)  # email only
    body_template = models.TextField()

    class Meta:
        db_table = "notification_templates"
        constraints = [
            models.UniqueConstraint(
                fields=["key", "channel", "language"], name="uq_notif_template"
            ),
        ]


class NotificationLog(TimestampedModel):
    recipient = models.ForeignKey(
        "identity.User", on_delete=models.CASCADE, db_column="recipient_id"
    )
    template_key = models.CharField(max_length=100)
    channel = models.CharField(max_length=10, choices=NotificationChannel.choices)
    status = models.CharField(
        max_length=10, choices=NotificationStatus.choices, default=NotificationStatus.PENDING
    )
    payload = models.JSONField(default=dict)
    provider_message_id = models.TextField(null=True, blank=True)
    error_message = models.TextField(null=True, blank=True)
    sent_at = models.DateTimeField(null=True, blank=True)
    delivered_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "notification_log"
        indexes = [models.Index(fields=["recipient", "-created_at"])]


class NotificationPreference(TimestampedModel):
    user = models.ForeignKey("identity.User", on_delete=models.CASCADE, db_column="user_id")
    event_category = models.CharField(max_length=100)
    channel = models.CharField(max_length=10, choices=NotificationChannel.choices)
    is_enabled = models.BooleanField(default=True)

    class Meta:
        db_table = "notification_preferences"
        constraints = [
            models.UniqueConstraint(
                fields=["user", "event_category", "channel"], name="uq_notif_pref"
            ),
        ]

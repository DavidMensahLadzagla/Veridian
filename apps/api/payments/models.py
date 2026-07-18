"""Payments, payouts, bank accounts (Layer 3). Money is INTEGER minor units + currency code —
never float. The payout_net_check invariant is enforced as a CHECK constraint.
"""

from __future__ import annotations

from django.contrib.postgres.fields import ArrayField
from django.db import models
from django.db.models import F, Q

from core.models import SoftDeleteModel, TimestampedModel


class PaymentProvider(models.TextChoices):
    PAYSTACK = "paystack", "Paystack"
    STRIPE = "stripe", "Stripe"
    CASH = "cash", "Cash"


class PaymentStatus(models.TextChoices):
    PENDING = "pending", "Pending"
    AUTHORIZED = "authorized", "Authorized"
    CAPTURED = "captured", "Captured"
    FAILED = "failed", "Failed"
    REFUNDED = "refunded", "Refunded"
    PARTIALLY_REFUNDED = "partially_refunded", "Partially refunded"
    DISPUTED = "disputed", "Disputed"


class PayoutStatus(models.TextChoices):
    PENDING = "pending", "Pending"
    PROCESSING = "processing", "Processing"
    COMPLETED = "completed", "Completed"
    FAILED = "failed", "Failed"


class PaymentTransaction(SoftDeleteModel):
    payer = models.ForeignKey("identity.User", on_delete=models.RESTRICT, db_column="payer_id")
    appointment = models.ForeignKey(
        "appointments.Appointment",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        db_column="appointment_id",
    )
    provider = models.CharField(max_length=20, choices=PaymentProvider.choices)
    provider_reference = models.CharField(max_length=255, unique=True, null=True, blank=True)
    amount = models.IntegerField()  # minor units
    currency_code = models.CharField(max_length=3, default="GHS")
    status = models.CharField(
        max_length=20, choices=PaymentStatus.choices, default=PaymentStatus.PENDING
    )
    provider_response = models.JSONField(default=dict)
    refunded_amount = models.IntegerField(default=0)
    refund_reason = models.TextField(null=True, blank=True)
    captured_at = models.DateTimeField(null=True, blank=True)
    failed_at = models.DateTimeField(null=True, blank=True)
    refunded_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "payment_transactions"
        indexes = [
            models.Index(fields=["payer", "-created_at"]),
            models.Index(fields=["appointment"]),
            models.Index(fields=["status"]),
            models.Index(fields=["provider_reference"]),
        ]
        constraints = [
            models.CheckConstraint(condition=Q(amount__gte=0), name="payment_amount_nonneg"),
            models.CheckConstraint(
                condition=Q(refunded_amount__gte=0), name="payment_refund_nonneg"
            ),
            models.CheckConstraint(
                condition=Q(refunded_amount__lte=F("amount")), name="refund_lte_amount"
            ),
        ]


class Payout(TimestampedModel):
    recipient = models.ForeignKey(
        "identity.User", on_delete=models.RESTRICT, db_column="recipient_id"
    )
    provider = models.CharField(
        max_length=20, choices=PaymentProvider.choices, default=PaymentProvider.PAYSTACK
    )
    provider_reference = models.CharField(max_length=255, unique=True, null=True, blank=True)
    gross_amount = models.IntegerField()
    platform_fee = models.IntegerField(default=0)
    tax_withheld_minor = models.IntegerField(default=0)
    tax_rate_bps = models.SmallIntegerField(default=0)  # e.g. 1500 = 15.00%
    net_amount = models.IntegerField()
    currency_code = models.CharField(max_length=3, default="GHS")
    status = models.CharField(
        max_length=20, choices=PayoutStatus.choices, default=PayoutStatus.PENDING
    )
    period_start = models.DateField()
    period_end = models.DateField()
    appointment_ids = ArrayField(models.UUIDField(), default=list)
    provider_response = models.JSONField(default=dict)
    processed_at = models.DateTimeField(null=True, blank=True)
    failed_at = models.DateTimeField(null=True, blank=True)
    failure_reason = models.TextField(null=True, blank=True)

    class Meta:
        db_table = "payouts"
        indexes = [
            models.Index(fields=["recipient", "-created_at"]),
            models.Index(fields=["status"]),
        ]
        constraints = [
            models.CheckConstraint(
                condition=Q(
                    net_amount=F("gross_amount") - F("platform_fee") - F("tax_withheld_minor")
                ),
                name="payout_net_check",
            ),
            models.CheckConstraint(
                condition=Q(period_end__gt=F("period_start")), name="payout_period_check"
            ),
            models.CheckConstraint(
                condition=Q(tax_rate_bps__gte=0) & Q(tax_rate_bps__lte=2500),
                name="payout_tax_rate_range",
            ),
        ]


class BankAccount(SoftDeleteModel):
    user = models.ForeignKey("identity.User", on_delete=models.CASCADE, db_column="user_id")
    bank_name = models.CharField(max_length=200)
    bank_code = models.CharField(max_length=20, null=True, blank=True)
    account_number = models.CharField(max_length=50)  # encrypted at application level
    account_name = models.CharField(max_length=200)
    is_verified = models.BooleanField(default=False)
    is_primary = models.BooleanField(default=False)
    currency_code = models.CharField(max_length=3, default="GHS")

    class Meta:
        db_table = "bank_accounts"

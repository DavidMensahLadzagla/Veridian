"""Custom user model — the single identity table for all roles (maps to `users`).

Auth is OTP + JWT (Termii/SimpleJWT), not passwords: users are created with an unusable
password. Role-specific data (patient_profiles, doctor_profiles) lives in separate tables.

The `password` column comes from AbstractBaseUser: NOT NULL, holding a '!'-prefixed unusable
marker for OTP users and a real hash only for platform_admin bootstrap (ADR-0006, reconciled
in veridian_schema.sql). Field mapping is otherwise aligned 1:1 to the canonical schema.
"""

from __future__ import annotations

import uuid
from typing import Any

from django.contrib.auth.base_user import AbstractBaseUser, BaseUserManager
from django.db import models

from core.models import TimestampedModel


class UserRole(models.TextChoices):
    PATIENT = "patient", "Patient"
    DOCTOR = "doctor", "Doctor"
    CLINIC_ADMIN = "clinic_admin", "Clinic admin"
    PLATFORM_ADMIN = "platform_admin", "Platform admin"


class Gender(models.TextChoices):
    MALE = "male", "Male"
    FEMALE = "female", "Female"
    NON_BINARY = "non_binary", "Non-binary"
    PREFER_NOT_TO_SAY = "prefer_not_to_say", "Prefer not to say"


class UserManager(BaseUserManager["User"]):
    use_in_migrations = True

    def create_user(
        self,
        *,
        full_name: str,
        email: str | None = None,
        phone: str | None = None,
        role: str = UserRole.PATIENT,
        password: str | None = None,
        **extra: Any,
    ) -> User:
        if not email and not phone:
            raise ValueError("A user must have either an email or a phone number.")
        user = self.model(
            email=self.normalize_email(email) if email else None,
            phone=phone,
            full_name=full_name,
            role=role,
            **extra,
        )
        # OTP/JWT auth — no usable password unless one is explicitly set (e.g. superuser).
        if password:
            user.set_password(password)
        else:
            user.set_unusable_password()
        user.save(using=self._db)
        return user

    def create_superuser(self, *, email: str, full_name: str, password: str, **extra: Any) -> User:
        return self.create_user(
            email=email,
            full_name=full_name,
            password=password,
            role=UserRole.PLATFORM_ADMIN,
            **extra,
        )


class User(AbstractBaseUser):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    email = models.EmailField(max_length=320, unique=True, null=True, blank=True)
    phone = models.CharField(max_length=20, unique=True, null=True, blank=True)
    phone_verified = models.BooleanField(default=False)
    email_verified = models.BooleanField(default=False)
    role = models.CharField(max_length=20, choices=UserRole.choices, default=UserRole.PATIENT)
    full_name = models.CharField(max_length=200)
    preferred_language = models.CharField(max_length=10, default="en")
    avatar_storage_key = models.TextField(null=True, blank=True)
    timezone = models.CharField(max_length=60, default="Africa/Accra")
    date_of_birth = models.DateField(null=True, blank=True)
    gender = models.CharField(max_length=20, choices=Gender.choices, null=True, blank=True)
    is_active = models.BooleanField(default=True)
    last_login = models.DateTimeField(db_column="last_login_at", null=True, blank=True)
    deleted_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    objects = UserManager()

    USERNAME_FIELD = "email"
    EMAIL_FIELD = "email"
    REQUIRED_FIELDS = ["full_name"]

    class Meta:
        db_table = "users"
        indexes = [
            models.Index(fields=["role"]),
        ]

    def __str__(self) -> str:
        return f"{self.full_name} <{self.email or self.phone}> ({self.role})"

    @property
    def is_staff(self) -> bool:
        return self.role == UserRole.PLATFORM_ADMIN


class UserAuthProvider(TimestampedModel):
    """OAuth providers linked to a user (Google, Apple). Tokens encrypted at app level."""

    user = models.ForeignKey(User, on_delete=models.CASCADE, db_column="user_id")
    provider = models.CharField(max_length=50)
    provider_uid = models.CharField(max_length=255)
    access_token = models.TextField(null=True, blank=True)
    refresh_token = models.TextField(null=True, blank=True)
    expires_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "user_auth_providers"
        constraints = [
            models.UniqueConstraint(
                fields=["provider", "provider_uid"], name="uq_auth_provider_uid"
            ),
        ]


class DeviceToken(TimestampedModel):
    """FCM/APNS push tokens per device per user."""

    class Platform(models.TextChoices):
        IOS = "ios", "iOS"
        ANDROID = "android", "Android"
        WEB = "web", "Web"

    user = models.ForeignKey(User, on_delete=models.CASCADE, db_column="user_id")
    token = models.TextField(unique=True)
    platform = models.CharField(max_length=10, choices=Platform.choices)
    is_active = models.BooleanField(default=True)
    last_used_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "device_tokens"


class RefreshTokenBlocklist(models.Model):
    """Revoked JWT refresh tokens (Redis is primary; this is the durable fallback)."""

    jti = models.UUIDField(primary_key=True)
    user = models.ForeignKey(User, on_delete=models.CASCADE, db_column="user_id")
    revoked_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()  # purge cron deletes rows past this date

    class Meta:
        db_table = "refresh_token_blocklist"
        indexes = [models.Index(fields=["expires_at"], name="idx_rtb_expires")]

    def __str__(self) -> str:
        return f"jti={self.jti} (revoked {self.revoked_at})"

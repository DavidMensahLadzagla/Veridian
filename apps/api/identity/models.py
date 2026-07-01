"""Custom user model — the single identity table for all roles (maps to `users`).

Auth is OTP + JWT (Termii/SimpleJWT), not passwords: users are created with an unusable
password. Role-specific data (patient_profiles, doctor_profiles) lives in separate tables.

NOTE (ADR-0006, pending): the canonical veridian_schema.sql `users` table has no `password`
column, which Django's AbstractBaseUser requires. Reconciling Django-managed auth columns with
the hand-written DDL is exactly what ADR-0006 (schema ownership) must decide before the 32
models land. This model is the skeleton; field mapping is aligned to the schema otherwise.
"""

from __future__ import annotations

import uuid
from typing import Any

from django.contrib.auth.base_user import AbstractBaseUser, BaseUserManager
from django.db import models


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
    ) -> "User":
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

    def create_superuser(
        self, *, email: str, full_name: str, password: str, **extra: Any
    ) -> "User":
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

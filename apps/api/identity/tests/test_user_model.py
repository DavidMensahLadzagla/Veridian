"""Custom user model — creation invariants and role defaults."""

import pytest
from django.contrib.auth import get_user_model

from identity.models import UserRole

User = get_user_model()


@pytest.mark.django_db
def test_create_user_requires_email_or_phone():
    with pytest.raises(ValueError):
        User.objects.create_user(full_name="No Contact")


@pytest.mark.django_db
def test_phone_only_user_defaults_to_patient_with_unusable_password():
    user = User.objects.create_user(full_name="Ama Mensah", phone="+233201234567")
    assert user.role == UserRole.PATIENT
    assert user.email is None
    assert user.has_usable_password() is False


@pytest.mark.django_db
def test_create_superuser_is_platform_admin_and_staff():
    admin = User.objects.create_superuser(
        email="admin@veridian.app", full_name="Root Admin", password="a-real-secret"
    )
    assert admin.role == UserRole.PLATFORM_ADMIN
    assert admin.is_staff is True
    assert admin.has_usable_password() is True

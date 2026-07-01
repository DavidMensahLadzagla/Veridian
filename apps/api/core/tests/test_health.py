"""Health endpoint: the Phase 0 exit criterion. Verifies the /api/v1/health contract."""

import pytest
from rest_framework.test import APIClient


@pytest.mark.django_db
def test_health_returns_healthy_when_db_and_cache_are_up():
    # DB (test sqlite) and cache (locmem) are both available in the test environment.
    client = APIClient()
    response = client.get("/api/v1/health")

    assert response.status_code == 200
    assert response.json() == {"status": "healthy", "db": "ok", "redis": "ok"}


@pytest.mark.django_db
def test_health_is_public_no_auth_required():
    # No Authorization header — must still succeed (health is unauthenticated).
    response = APIClient().get("/api/v1/health")
    assert response.status_code == 200

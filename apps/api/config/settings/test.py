"""Test settings.

BOOTSTRAP NOTE (Phase 0 only): uses in-memory SQLite + local-memory cache so the foundation
test suite runs with zero external services. This is safe *only* while there are no models with
Postgres-specific types. The moment the 32-table schema lands (ADR-0006), switch the test
database to Postgres (CI already provisions a Postgres service) — integration tests must run
against Postgres so RLS, triggers, JSONB/UUID/VECTOR/GEOGRAPHY behaviour is real.
"""

from .base import *  # noqa: F401,F403

DEBUG = False

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": ":memory:",
    },
}

CACHES = {
    "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"},
}

PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]  # faster tests only

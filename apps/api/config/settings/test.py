"""Test settings.

Runs against Postgres + PostGIS (NOT sqlite): the models use VECTOR, GEOGRAPHY, ARRAY, JSONB,
and CHECK constraints that only Postgres honours, and RLS/triggers must be real (ADR-0006).
CI provisions a postgis service and sets DATABASE_URL; locally, point DATABASE_URL at a
postgis database. The cache is swapped to local-memory so tests need no Redis.
"""

from .base import *  # noqa: F401,F403

DEBUG = False

CACHES = {
    "default": {"BACKEND": "django.core.cache.backends.locmem.LocMemCache"},
}

PASSWORD_HASHERS = ["django.contrib.auth.hashers.MD5PasswordHasher"]  # faster tests only

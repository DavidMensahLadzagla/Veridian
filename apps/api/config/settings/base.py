"""Base Django settings for Veridian. Environment-specific modules import from here.

Secrets and environment-varying values come from environment variables only (never hardcoded),
per the threat model. See .env.example for the full list.
"""

from __future__ import annotations

import os
from pathlib import Path

import dj_database_url

BASE_DIR = Path(__file__).resolve().parent.parent.parent


def env(key: str, default: str | None = None, *, required: bool = False) -> str:
    value = os.environ.get(key, default)
    if required and not value:
        raise RuntimeError(f"Required environment variable {key!r} is not set")
    return value or ""


def env_bool(key: str, default: bool = False) -> bool:
    return env(key, str(default)).strip().lower() in {"1", "true", "yes", "on"}


def env_list(key: str, default: str = "") -> list[str]:
    return [item.strip() for item in env(key, default).split(",") if item.strip()]


# --- Core ---------------------------------------------------------------------
SECRET_KEY = env("DJANGO_SECRET_KEY", "insecure-dev-key-override-in-every-env")
DEBUG = env_bool("DJANGO_DEBUG", False)
ALLOWED_HOSTS = env_list("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1")

INSTALLED_APPS = [
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "rest_framework",
    # Veridian apps
    "core",
    "identity",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.middleware.common.CommonMiddleware",
]

ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"
ASGI_APPLICATION = "config.asgi.application"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {"context_processors": []},
    },
]

# --- Database (Supabase Postgres via PgBouncer) -------------------------------
# `check` does not connect; runtime/tests require a reachable database.
DATABASES = {
    "default": dj_database_url.parse(
        env("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/veridian"),
        conn_max_age=600,
    ),
}

# --- Cache / Redis ------------------------------------------------------------
CACHES = {
    "default": {
        "BACKEND": "django_redis.cache.RedisCache",
        "LOCATION": env("REDIS_URL", "redis://localhost:6379/0"),
        "OPTIONS": {"CLIENT_CLASS": "django_redis.client.DefaultClient"},
    },
}

# --- Auth ---------------------------------------------------------------------
AUTH_USER_MODEL = "identity.User"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"  # only for non-UUID internal tables

# --- DRF: explicit, secure defaults (mass-assignment + error-envelope discipline) ---
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework_simplejwt.authentication.JWTAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticated",
    ],
    "EXCEPTION_HANDLER": "core.exceptions.veridian_exception_handler",
    "DEFAULT_RENDERER_CLASSES": ["rest_framework.renderers.JSONRenderer"],
    "UNAUTHENTICATED_USER": None,
}

# --- i18n / tz ----------------------------------------------------------------
LANGUAGE_CODE = "en"
TIME_ZONE = "UTC"  # server runs in UTC; slot instants are stored tz-aware (ADR-0004)
USE_I18N = True
USE_TZ = True

PASSWORD_HASHERS = ["django.contrib.auth.hashers.Argon2PasswordHasher"]

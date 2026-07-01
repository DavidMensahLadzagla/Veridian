"""Production settings. DEBUG must never be true here (threat model I-5)."""

from .base import *  # noqa: F401,F403
from .base import env, env_bool

DEBUG = False

# Fail loudly if a real secret was not provided.
SECRET_KEY = env("DJANGO_SECRET_KEY", required=True)

# Security headers / TLS (Railway terminates TLS; HSTS + secure cookies enforced here).
SECURE_SSL_REDIRECT = env_bool("DJANGO_SECURE_SSL_REDIRECT", True)
SECURE_HSTS_SECONDS = 63072000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = True
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_CONTENT_TYPE_NOSNIFF = True

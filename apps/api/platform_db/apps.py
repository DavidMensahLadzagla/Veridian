"""No-model app owning the database platform layer (ADR-0006 / ADR-0007).

Holds only hand-authored RunSQL migrations: the Supabase-compat shim, extensions,
triggers/functions, and the RLS/GRANT layer. Because there are no models here,
`makemigrations` never touches this app and `--check` stays green.
"""

from django.apps import AppConfig


class PlatformDbConfig(AppConfig):
    name = "platform_db"
    verbose_name = "Platform DB (RunSQL layer)"

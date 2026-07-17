"""Supabase-compatibility shim (ADR-0007).

Provisions the Supabase-only objects (roles anon/authenticated/service_role,
schema auth, function auth.uid()) ONLY when absent, so the RLS/GRANT layer
applies identically on Supabase, CI, local dev, and the Django test database.
On Supabase every object already exists and the shim is a no-op — it never
touches the real auth schema.

reverse_sql is a hard no-op: a downward migration must never drop auth objects
(on Supabase they are GoTrue's, and roles are cluster-wide).

Validated end-to-end against Postgres 17.9 on 2026-07-03 (see ADR-0007).
"""

from django.db import migrations

from ._sql import read_sql


class Migration(migrations.Migration):
    initial = True

    # Cluster-level state only (roles, auth schema) — no model dependencies.
    dependencies: list[tuple[str, str]] = []

    operations = [
        migrations.RunSQL(
            sql=read_sql("0001_supabase_compat_shim.sql"),
            reverse_sql=migrations.RunSQL.noop,
        ),
    ]

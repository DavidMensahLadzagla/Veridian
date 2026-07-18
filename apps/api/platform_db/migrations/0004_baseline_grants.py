"""Supabase-baseline privilege emulation (ADR-0007 compat surface).

Grants anon/authenticated/service_role the blanket public-schema privileges
they hold by default on Supabase, so that on plain Postgres (CI, local,
test-DB) the RLS policy layer is actually reachable — without this, client
roles fail on table-level permission before any policy is evaluated.

Must sit between the model tables (0003's deps) and the RLS/REVOKE layer
(0005): the canonical REVOKEs subtract from this baseline, exactly as on
Supabase. reverse_sql is a no-op — revoking a baseline that Supabase
provisions natively would desync environments on a downward migration.
"""

from django.db import migrations

from ._sql import read_sql


class Migration(migrations.Migration):
    dependencies = [
        ("platform_db", "0003_functions_triggers"),
    ]

    operations = [
        migrations.RunSQL(
            sql=read_sql("0004_baseline_grants.sql"),
            reverse_sql=migrations.RunSQL.noop,
        ),
    ]

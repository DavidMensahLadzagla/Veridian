"""Postgres extensions (verbatim from plans/veridian_schema.sql, ADR-0006).

Must run before any model migration: doctors.0001 creates a PostGIS geometry
column (clinics.location) and a pgvector column (doctor_profiles
.profile_embedding), hence the run_before edges on every app's 0001_initial.

reverse_sql is a no-op: extensions are cluster-shared; a downward migration
of this app must never drop them out from under other databases/schemas.
"""

from django.db import migrations

from ._sql import read_sql


class Migration(migrations.Migration):
    dependencies = [
        ("platform_db", "0001_supabase_compat_shim"),
    ]

    run_before = [
        ("core", "0001_initial"),
        ("identity", "0001_initial"),
        ("doctors", "0001_initial"),
        ("appointments", "0001_initial"),
        ("health_records", "0001_initial"),
        ("notifications", "0001_initial"),
        ("payments", "0001_initial"),
    ]

    operations = [
        migrations.RunSQL(
            sql=read_sql("0002_extensions.sql"),
            reverse_sql=migrations.RunSQL.noop,
        ),
    ]

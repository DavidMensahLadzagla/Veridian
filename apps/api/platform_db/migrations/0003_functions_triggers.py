"""Class A platform SQL: portable functions + triggers (ADR-0006).

Verbatim from plans/veridian_schema.sql: set_updated_at() + its 26 per-table
triggers, the audit_log append-only guards, and the audit_log_chain() SHA-256
hash-chain trigger — plus the two model/DDL reconciliation ALTERs
(patient_profiles.patient_key_salt default + NOT NULL, audit_log.row_hash
NOT NULL) that must run only after the trigger/default exist.

Depends on every app's initial migrations because the triggers attach to
those tables (appointments contributes 0002_initial — its FK cycle breaker).
"""

from django.db import migrations

from ._sql import read_sql


class Migration(migrations.Migration):
    dependencies = [
        ("platform_db", "0002_extensions"),
        ("core", "0001_initial"),
        ("identity", "0001_initial"),
        ("doctors", "0001_initial"),
        ("appointments", "0002_initial"),
        ("health_records", "0001_initial"),
        ("notifications", "0001_initial"),
        ("payments", "0001_initial"),
    ]

    operations = [
        migrations.RunSQL(
            sql=read_sql("0003_functions_triggers.sql"),
            reverse_sql=read_sql("0003_functions_triggers_reverse.sql"),
        ),
    ]

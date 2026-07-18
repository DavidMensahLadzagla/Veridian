"""Seed data: service_categories + feature_flags (canonical values from
plans/veridian_schema.sql "SEED DATA" blocks).

Column lists differ from the canonical INSERTs on purpose — Django-generated
tables have no DB defaults for id/created_at/updated_at/metadata, so the SQL
supplies them; see the comment at the top of the .sql file. Idempotent via
ON CONFLICT DO NOTHING on the natural keys (slug / key), so an already-seeded
database is never clobbered.

Depends on core's initial migration (owns both tables). Sequenced after 0005
so the whole platform_db chain stays linear.
"""

from django.db import migrations

from ._sql import read_sql


class Migration(migrations.Migration):
    dependencies = [
        ("platform_db", "0005_rls_policies_grants"),
        ("core", "0001_initial"),
    ]

    operations = [
        migrations.RunSQL(
            sql=read_sql("0006_seed_data.sql"),
            reverse_sql=read_sql("0006_seed_data_reverse.sql"),
        ),
    ]

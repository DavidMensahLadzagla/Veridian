"""Class B security layer: RLS + policies + v_appointments_safe + GRANT/REVOKE.

Verbatim from plans/veridian_schema.sql (hardened per ADR-0001: TO role +
ownership predicate, WITH CHECK on every ALL/UPDATE/INSERT policy,
(SELECT auth.uid()) wrapping). Applies on plain Postgres because 0001's shim
guarantees auth.uid() and the anon/authenticated/service_role roles exist
(ADR-0007) — which is what lets CI and the test-DB exercise this layer.

The reverse drops policies/view and disables RLS but deliberately does NOT
undo the REVOKEs — see the comment at the top of the reverse .sql.
"""

from django.db import migrations

from ._sql import read_sql


class Migration(migrations.Migration):
    dependencies = [
        ("platform_db", "0004_baseline_grants"),
    ]

    operations = [
        migrations.RunSQL(
            sql=read_sql("0005_rls_policies_grants.sql"),
            reverse_sql=read_sql("0005_rls_policies_grants_reverse.sql"),
        ),
    ]

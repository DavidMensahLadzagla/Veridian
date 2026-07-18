"""Loader for the versioned .sql files that back this app's RunSQL migrations.

The SQL is the text of record (sourced verbatim from plans/veridian_schema.sql,
per ADR-0006); the Python migration modules only sequence and wire dependencies.
"""

from pathlib import Path

_SQL_DIR = Path(__file__).resolve().parent / "sql"


def read_sql(filename: str) -> str:
    return (_SQL_DIR / filename).read_text()

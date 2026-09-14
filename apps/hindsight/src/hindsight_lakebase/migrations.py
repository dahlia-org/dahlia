"""Initial Lakebase text schema setup; no existing-data conversion."""

import json
import os
import subprocess
import sys

from sqlalchemy import create_engine, text
from sqlalchemy.pool import NullPool

from .text import TABLES, quoted


def historical_migrations(database_url, script_location, schema):
    """Keep historical Alembic revisions intact and isolate compatibility settings."""
    from hindsight_api.config import get_config

    config = get_config()
    env = dict(os.environ)
    if config.text_search_extension == "lakebase_text":
        env["HINDSIGHT_API_TEXT_SEARCH_EXTENSION"] = "native"
    if config.vector_extension == "lakebase_vector":
        env["HINDSIGHT_API_VECTOR_EXTENSION"] = "pgvector"
    subprocess.run(
        [sys.executable, "-m", "hindsight_lakebase.migrations"],
        input=json.dumps([database_url, script_location, schema]),
        text=True,
        env=env,
        check=True,
    )


def ensure_text(database_url, schema=None):
    from hindsight_api.db_url import to_libpq_url

    schema = schema or "public"
    engine = create_engine(to_libpq_url(database_url), poolclass=NullPool)
    try:
        with engine.begin() as conn:
            conn.execute(text("CREATE EXTENSION IF NOT EXISTS lakebase_text WITH SCHEMA public"))
            for table in TABLES:
                full = f"{quoted(schema)}.{quoted(table)}"
                # A normal tsvector lets Python supply the Japanese-tokenized text.
                # DROP EXPRESSION preserves the column and is idempotent on restart.
                conn.execute(text(f"ALTER TABLE {full} ALTER COLUMN search_vector DROP EXPRESSION IF EXISTS"))
                index = f"{quoted(schema)}.{quoted('idx_' + table + '_text_search')}"
                method = conn.execute(
                    text(
                        "SELECT am.amname FROM pg_class c JOIN pg_am am ON am.oid = c.relam "
                        "WHERE c.oid = to_regclass(:index)"
                    ),
                    {"index": index},
                ).scalar()
                if method == "gin":
                    conn.execute(text(f"DROP INDEX {index}"))
    finally:
        engine.dispose()


if __name__ == "__main__":
    from hindsight_api.migrations import _run_migrations_internal

    _run_migrations_internal(*json.load(sys.stdin))

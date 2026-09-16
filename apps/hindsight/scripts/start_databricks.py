"""Start Hindsight with the Lakebase resource injected by Databricks Apps."""

import os
from contextlib import closing
from urllib.parse import quote, urlencode, urlunsplit

from hindsight_lakebase.databricks import (
    get_lakebase_credential_provider,
    lakebase_database_auth_enabled,
)

EXTENSIONS = ("vector", "pg_trgm", "lakebase_text", "lakebase_vector")


def database_url(env=os.environ):
    required = ("PGHOST", "PGDATABASE", "PGUSER")
    missing = [name for name in required if not env.get(name)]
    password = env.get("PGPASSWORD")
    if not password and not lakebase_database_auth_enabled(env):
        missing.append("PGPASSWORD")
    if missing:
        raise RuntimeError(f"Missing Databricks PostgreSQL variables: {', '.join(missing)}")

    user = quote(env["PGUSER"], safe="")
    credentials = f":{quote(password, safe='')}" if password else ""
    database = quote(env["PGDATABASE"], safe="")
    port = env.get("PGPORT", "5432")
    query = urlencode({"sslmode": env.get("PGSSLMODE", "require")})
    return urlunsplit(("postgresql", f"{user}{credentials}@{env['PGHOST']}:{port}", f"/{database}", query, ""))


def prepare_extensions(cursor):
    cursor.execute("SET LOCAL lock_timeout = '5s'")
    cursor.execute("SET LOCAL statement_timeout = '60s'")
    cursor.execute("SELECT pg_advisory_xact_lock(75047176522050)")
    for extension in EXTENSIONS:
        cursor.execute(
            "SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = %s",
            (extension,),
        )
        existing = cursor.fetchone()
        if existing and existing[0] != "public":
            raise RuntimeError(f"extension_schema_mismatch: {extension} must be installed in public")
        cursor.execute(f"CREATE EXTENSION IF NOT EXISTS {extension} WITH SCHEMA public")


def prepare_database(url):
    import psycopg2

    with closing(psycopg2.connect(url)) as connection:
        with connection, connection.cursor() as cursor:
            prepare_extensions(cursor)


def main():
    url = database_url()
    startup_url = url
    if lakebase_database_auth_enabled():
        startup_url = database_url({**os.environ, "PGPASSWORD": get_lakebase_credential_provider().get_token()})
    prepare_database(startup_url)
    os.environ["HINDSIGHT_API_DATABASE_URL"] = url
    os.environ["HINDSIGHT_API_MIGRATION_DATABASE_URL"] = url
    if lakebase_database_auth_enabled():
        os.environ["HINDSIGHT_API_DATABASE_PASSWORD_PROVIDER"] = "databricks"
    port = os.environ.get("DATABRICKS_APP_PORT", "8000")
    os.execvp("hindsight-api", ["hindsight-api", "--host", "0.0.0.0", "--port", port])


if __name__ == "__main__":
    main()

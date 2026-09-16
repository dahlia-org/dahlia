import asyncio
import json
import os
import unittest
from datetime import UTC, datetime
from unittest.mock import Mock, patch

from scripts import start_databricks

from hindsight_lakebase.databricks import (
    DatabricksLakebaseCredentialProvider,
    DatabricksOAuthTokenProvider,
    refresh_lakebase_database_url,
)


class Response:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def read(self):
        return json.dumps(self.body).encode()


class DatabricksStartTests(unittest.TestCase):
    def test_app_oauth_token_is_cached_and_refreshed(self):
        now = [100.0]
        requests = []

        def open_token(request, timeout):
            requests.append((request, timeout))
            return Response({"access_token": f"token-{len(requests)}", "expires_in": 120})

        provider = DatabricksOAuthTokenProvider(
            "https://workspace.cloud.databricks.com/",
            "client",
            "secret",
            opener=open_token,
            clock=lambda: now[0],
        )
        self.assertEqual(provider.get_token(), "token-1")
        self.assertEqual(asyncio.run(provider.get_token_async()), "token-1")
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0][0].full_url, "https://workspace.cloud.databricks.com/oidc/v1/token")
        self.assertEqual(requests[0][0].data, b"grant_type=client_credentials&scope=all-apis")
        self.assertEqual(requests[0][0].get_header("Authorization"), "Basic Y2xpZW50OnNlY3JldA==")
        self.assertIsNone(requests[0][0].get_header("x-forwarded-access-token"))
        self.assertEqual(requests[0][1], 30)

        now[0] = 161.0
        self.assertEqual(provider.get_token(), "token-2")
        self.assertEqual(len(requests), 2)

    def test_app_oauth_uses_the_ai_gateway_on_the_injected_workspace(self):
        provider = DatabricksOAuthTokenProvider.from_env(
            {
                "DATABRICKS_HOST": "workspace.cloud.databricks.com",
                "DATABRICKS_CLIENT_ID": "client",
                "DATABRICKS_CLIENT_SECRET": "secret",
            }
        )
        self.assertEqual(
            provider.ai_gateway_base_url,
            "https://workspace.cloud.databricks.com/ai-gateway/mlflow/v1",
        )
        self.assertEqual(
            provider.resolve_ai_gateway_base_url("https://workspace.cloud.databricks.com/custom/v1"),
            "https://workspace.cloud.databricks.com/custom/v1",
        )
        with self.assertRaisesRegex(RuntimeError, "workspace origin"):
            provider.resolve_ai_gateway_base_url("https://proxy.example/v1")

    def test_lakebase_credential_is_cached_and_refreshed(self):
        now = [1000.0]
        requests = []

        class Auth:
            host = "https://workspace.cloud.databricks.com"

            def get_token(self):
                return "workspace-token"

        def open_credential(request, timeout):
            requests.append((request, timeout))
            expires_at = 1500 if len(requests) == 1 else 2000
            return Response(
                {
                    "token": f"db-token-{len(requests)}",
                    "expire_time": datetime.fromtimestamp(expires_at, UTC).isoformat().replace("+00:00", "Z"),
                }
            )

        provider = DatabricksLakebaseCredentialProvider(
            Auth(),
            "projects/project/branches/production/endpoints/app",
            opener=open_credential,
            clock=lambda: now[0],
        )
        self.assertEqual(provider.get_token(), "db-token-1")
        self.assertEqual(provider.get_token(), "db-token-1")
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0][0].full_url, "https://workspace.cloud.databricks.com/api/2.0/postgres/credentials")
        self.assertEqual(
            json.loads(requests[0][0].data), {"endpoint": "projects/project/branches/production/endpoints/app"}
        )
        self.assertEqual(requests[0][0].get_header("Authorization"), "Bearer workspace-token")
        self.assertEqual(requests[0][1], 30)

        now[0] = 1400
        self.assertEqual(provider.get_token(), "db-token-2")
        self.assertEqual(len(requests), 2)

    def test_database_url_encodes_injected_credentials(self):
        self.assertEqual(
            start_databricks.database_url(
                {
                    "PGHOST": "db.example.com",
                    "PGDATABASE": "shared db",
                    "PGUSER": "app@example.com",
                    "PGPASSWORD": "a/b?c",
                    "PGPORT": "5432",
                    "PGSSLMODE": "require",
                }
            ),
            "postgresql:"
            "//app%40example.com:a%2Fb%3Fc@db.example.com:5432/shared%20db?sslmode=require",
        )

    def test_main_starts_hindsight_on_the_databricks_port(self):
        env = {
            "PGHOST": "db.example.com",
            "PGDATABASE": "databricks-postgres",
            "PGUSER": "app",
            "PGPASSWORD": "secret",
            "DATABRICKS_HOST": "https://workspace.cloud.databricks.com/",
            "DATABRICKS_APP_PORT": "9000",
            "HINDSIGHT_API_LLM_BASE_URL": "https://custom.example/llm/v1",
            "HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL": "https://custom.example/embeddings/v1",
        }
        executed = {}

        def execvp(file, args):
            executed.update(
                file=file,
                args=args,
                url=os.environ["HINDSIGHT_API_DATABASE_URL"],
                llm_base_url=os.environ["HINDSIGHT_API_LLM_BASE_URL"],
                embeddings_base_url=os.environ["HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL"],
            )

        with (
            patch.dict(os.environ, env, clear=True),
            patch.object(start_databricks, "prepare_database") as prepare,
            patch.object(os, "execvp", execvp),
        ):
            start_databricks.main()

            self.assertEqual(os.environ["HINDSIGHT_API_MIGRATION_DATABASE_URL"], executed["url"])
            prepare.assert_called_once_with(executed["url"])

        self.assertEqual(
            executed,
            {
                "file": "hindsight-api",
                "args": ["hindsight-api", "--host", "0.0.0.0", "--port", "9000"],
                "url": "postgresql:"
                "//app:secret@db.example.com:5432/databricks-postgres?sslmode=require",
                "llm_base_url": "https://custom.example/llm/v1",
                "embeddings_base_url": "https://custom.example/embeddings/v1",
            },
        )

    def test_database_url_requires_the_resource_password(self):
        with self.assertRaisesRegex(RuntimeError, "PGPASSWORD"):
            start_databricks.database_url({"PGHOST": "db", "PGDATABASE": "db", "PGUSER": "app"})

    def test_databricks_database_url_uses_a_refreshable_credential(self):
        env = {
            "PGHOST": "db.example.com",
            "PGDATABASE": "databricks-postgres",
            "PGUSER": "app",
            "HINDSIGHT_API_DATABASE_PASSWORD_PROVIDER": "databricks",
        }
        self.assertEqual(
            start_databricks.database_url(env),
            "postgresql://app@db.example.com:5432/databricks-postgres?sslmode=require",
        )

    def test_refreshable_credential_preserves_encoded_database_user(self):
        provider = Mock()
        provider.get_token.return_value = "db/token"
        env = {"HINDSIGHT_API_DATABASE_PASSWORD_PROVIDER": "databricks", "PGUSER": "app@example.com"}
        with (
            patch.dict(os.environ, env, clear=True),
            patch("hindsight_lakebase.databricks.get_lakebase_credential_provider", return_value=provider),
        ):
            for scheme in ("postgresql", "postgresql+asyncpg"):
                with self.subTest(scheme=scheme):
                    self.assertEqual(
                        refresh_lakebase_database_url(f"{scheme}://app%40example.com@db.example.com:5432/db"),
                        f"{scheme}://app%40example.com:db%2Ftoken@db.example.com:5432/db",
                    )

    def test_main_fetches_a_fresh_databricks_database_credential(self):
        env = {
            "PGHOST": "db.example.com",
            "PGDATABASE": "databricks-postgres",
            "PGUSER": "app",
            "LAKEBASE_ENDPOINT": "projects/project/branches/production/endpoints/app",
            "HINDSIGHT_API_DATABASE_PASSWORD_PROVIDER": "databricks",
            "DATABRICKS_HOST": "https://workspace.cloud.databricks.com",
            "DATABRICKS_CLIENT_ID": "client",
            "DATABRICKS_CLIENT_SECRET": "secret",
            "DATABRICKS_APP_PORT": "9000",
        }
        executed = {}
        provider = Mock()
        provider.get_token.return_value = "db-token"

        def execvp(file, args):
            executed.update(
                file=file,
                args=args,
                database_url=os.environ["HINDSIGHT_API_DATABASE_URL"],
                migration_url=os.environ["HINDSIGHT_API_MIGRATION_DATABASE_URL"],
            )

        with (
            patch.dict(os.environ, env, clear=True),
            patch.object(start_databricks, "get_lakebase_credential_provider", return_value=provider),
            patch.object(start_databricks, "prepare_database") as prepare,
            patch.object(os, "execvp", execvp),
        ):
            start_databricks.main()

        prepare.assert_called_once_with(
            "postgresql:"
            "//app:db-token@db.example.com:5432/databricks-postgres?sslmode=require"
        )
        self.assertEqual(
            executed["database_url"], "postgresql://app@db.example.com:5432/databricks-postgres?sslmode=require"
        )
        self.assertEqual(
            executed["migration_url"], "postgresql://app@db.example.com:5432/databricks-postgres?sslmode=require"
        )

    def test_postgres_pool_uses_a_password_callback_for_databricks(self):
        from hindsight_api.engine.db.postgresql import PostgreSQLBackend

        from hindsight_lakebase.databricks import lakebase_database_password_async

        captured = {}

        async def create_pool(*args, **kwargs):
            captured.update(args=args, kwargs=kwargs)
            return Mock()

        env = {
            "HINDSIGHT_API_DATABASE_PASSWORD_PROVIDER": "databricks",
            "LAKEBASE_ENDPOINT": "projects/project/branches/production/endpoints/app",
            "DATABRICKS_HOST": "https://workspace.cloud.databricks.com",
            "DATABRICKS_CLIENT_ID": "client",
            "DATABRICKS_CLIENT_SECRET": "secret",
        }
        with patch.dict(os.environ, env, clear=False), patch("asyncpg.create_pool", create_pool):
            asyncio.run(
                PostgreSQLBackend().initialize("postgresql://app@db.example.com:5432/db", min_size=1, max_size=1)
            )

        self.assertIs(captured["kwargs"]["password"], lakebase_database_password_async)

    def test_prepare_extensions_rejects_an_existing_private_extension(self):
        cursor = Mock()
        cursor.fetchone.return_value = ("app",)

        with self.assertRaisesRegex(RuntimeError, "extension_schema_mismatch: vector"):
            start_databricks.prepare_extensions(cursor)

        statements = "\n".join(call.args[0] for call in cursor.execute.call_args_list)
        self.assertIn("pg_advisory_xact_lock(75047176522050)", statements)
        self.assertNotIn("DROP EXTENSION", statements)

    def test_prepare_extensions_installs_every_shared_extension_in_public(self):
        cursor = Mock()
        cursor.fetchone.side_effect = [None] * len(start_databricks.EXTENSIONS)

        start_databricks.prepare_extensions(cursor)

        statements = [call.args[0] for call in cursor.execute.call_args_list]
        for extension in start_databricks.EXTENSIONS:
            self.assertIn(f"CREATE EXTENSION IF NOT EXISTS {extension} WITH SCHEMA public", statements)


if __name__ == "__main__":
    unittest.main()

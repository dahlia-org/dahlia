from unittest.mock import MagicMock

import pytest

from hindsight_lakebase import migrations


def test_historical_migrations_only_map_child_environment(lakebase, monkeypatch):
    from hindsight_api.config import get_config

    run = MagicMock()
    monkeypatch.setattr(migrations.subprocess, "run", run)
    migrations.historical_migrations("postgresql://example/test", "/source/alembic", "tenant_a")
    args, kwargs = run.call_args
    assert "postgresql://example/test" not in str(args)
    assert "postgresql://example/test" in kwargs["input"]
    assert kwargs["env"]["HINDSIGHT_API_TEXT_SEARCH_EXTENSION"] == "native"
    assert kwargs["env"]["HINDSIGHT_API_VECTOR_EXTENSION"] == "pgvector"
    assert get_config().text_search_extension == "lakebase_text"
    assert get_config().vector_extension == "lakebase_vector"


@pytest.mark.parametrize("method", ["gin", "lakebase_bm25", None])
def test_text_setup_preserves_bm25_without_backfill(monkeypatch, method):
    engine = MagicMock()
    conn = engine.begin.return_value.__enter__.return_value
    conn.execute.return_value.scalar.return_value = method
    monkeypatch.setattr(migrations, "create_engine", lambda *args, **kwargs: engine)
    migrations.ensure_text("postgresql://example/test", "tenant_a")
    sql = [str(call.args[0]) for call in conn.execute.call_args_list]
    assert sum("DROP INDEX" in statement for statement in sql) == (2 if method == "gin" else 0)
    assert not any(word in statement for statement in sql for word in ["UPDATE ", "CREATE INDEX", "COMMENT "])
    engine.dispose.assert_called_once()


@pytest.mark.parametrize(
    "text_backend,vector_backend",
    [
        ("native", "pgvector"),
        ("lakebase_text", "pgvector"),
        ("native", "lakebase_vector"),
        ("lakebase_text", "lakebase_vector"),
    ],
)
def test_backends_select_independently(monkeypatch, text_backend, vector_backend):
    from hindsight_api.config import get_config

    monkeypatch.setenv("HINDSIGHT_API_TEXT_SEARCH_EXTENSION", text_backend)
    monkeypatch.setenv("HINDSIGHT_API_VECTOR_EXTENSION", vector_backend)
    assert get_config().text_search_extension == text_backend
    assert get_config().vector_extension == vector_backend


def test_lakebase_rejects_oracle(lakebase, monkeypatch):
    from hindsight_api.config import get_config

    monkeypatch.setenv("HINDSIGHT_API_DATABASE_BACKEND", "oracle")
    with pytest.raises(ValueError, match="Lakebase search requires"):
        get_config()


@pytest.mark.parametrize("backend", ["native", "vchord", "pg_textsearch", "pgroonga", "pg_search"])
def test_other_backends_do_not_initialize_lakebase_text(monkeypatch, backend):
    from hindsight_api import migrations as upstream

    setup = MagicMock()
    monkeypatch.setattr(migrations, "ensure_text", setup)
    # Stop at the existing backend's database boundary; no Lakebase setup should run.
    monkeypatch.setattr(upstream, "create_engine", MagicMock(side_effect=RuntimeError("upstream DB")))
    with pytest.raises(RuntimeError, match="upstream DB"):
        upstream.ensure_text_search_extension("postgresql://example/test", backend)
    setup.assert_not_called()


def test_native_migrations_do_not_spawn_compatibility_process(monkeypatch):
    from hindsight_api import migrations as upstream

    run = MagicMock()
    monkeypatch.setattr(migrations.subprocess, "run", run)
    monkeypatch.setattr(upstream.command, "upgrade", MagicMock())
    upstream._run_migrations_internal("postgresql://example/test", "/source/alembic", "tenant_a")
    run.assert_not_called()


@pytest.mark.parametrize(
    "backend,table,creates_index",
    [
        ("lakebase_vector", "memory_units", False),
        ("lakebase_vector", "mental_models", True),
        ("pgvector", "memory_units", True),
    ],
)
def test_dimension_change_preserves_lakebase_bank_index_ownership(backend, table, creates_index):
    from hindsight_api import migrations as upstream

    conn = MagicMock()
    conn.execute.return_value.scalar.side_effect = [384, 0]
    upstream._migrate_table_embedding_dimension(conn, "tenant_a", table, 1536, backend)
    sql = [str(call.args[0]) for call in conn.execute.call_args_list]
    assert any(f"ALTER TABLE tenant_a.{table} ALTER COLUMN embedding TYPE vector(1536)" in query for query in sql)
    assert any("CREATE INDEX" in query for query in sql) == creates_index
    # Existing Lakebase ANN indexes are found and dropped before the column type changes.
    assert any("'lakebase_ann'" in query and "pg_am" in query for query in sql)
    conn.commit.assert_called()

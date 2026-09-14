"""Opt-in tests: only use dedicated, disposable databases, never application DBs."""

import os
import uuid

import asyncpg
import pytest
from sqlalchemy import create_engine
from sqlalchemy import text as sql
from sqlalchemy.pool import NullPool

from hindsight_lakebase.text import quoted


def configure(monkeypatch, backend):
    variable = "HINDSIGHT_TEST_LAKEBASE_URL" if backend == "lakebase" else "HINDSIGHT_TEST_POSTGRES_URL"
    url = os.environ.get(variable)
    if not url:
        pytest.skip(f"{variable} is not configured")
    schema = "hindsight_test_" + uuid.uuid4().hex
    monkeypatch.setenv("HINDSIGHT_API_DATABASE_URL", url)
    monkeypatch.setenv("HINDSIGHT_API_DATABASE_SCHEMA", schema)
    monkeypatch.setenv("HINDSIGHT_API_TEXT_SEARCH_EXTENSION", "lakebase_text" if backend == "lakebase" else "native")
    monkeypatch.setenv("HINDSIGHT_API_VECTOR_EXTENSION", "lakebase_vector" if backend == "lakebase" else "pgvector")
    from hindsight_api.config import clear_config_cache

    clear_config_cache()
    return url, schema


def migrate(url, schema, backend):
    from hindsight_api.migrations import run_migrations_for_schemas

    run_migrations_for_schemas(
        url,
        [schema],
        embedding_dimension=3,
        text_search_extension="lakebase_text" if backend == "lakebase" else "native",
        vector_extension="lakebase_vector" if backend == "lakebase" else "pgvector",
        ensure_extensions=True,
    )


def drop_test_schema(url, schema):
    # Only the fresh UUID schema allocated by this test is removed.
    assert schema.startswith("hindsight_test_")
    from hindsight_api.db_url import to_libpq_url

    engine = create_engine(to_libpq_url(url), poolclass=NullPool)
    try:
        with engine.begin() as conn:
            conn.execute(sql(f"DROP SCHEMA IF EXISTS {quoted(schema)} CASCADE"))
    finally:
        engine.dispose()


async def insert_fact(conn, bank, sentence, embedding="[1,0,0]"):
    from hindsight_api.engine.db.ops_postgresql import PostgreSQLOps

    return (
        await PostgreSQLOps().insert_facts_batch(
            conn,
            bank_id=bank,
            fact_texts=[sentence],
            embeddings=[embedding],
            event_dates=[None],
            occurred_starts=[None],
            occurred_ends=[None],
            mentioned_ats=[None],
            contexts=[""],
            fact_types=["world"],
            metadata_jsons=["{}"],
            chunk_ids=[None],
            document_ids=[None],
            tags_list=['["visible"]'],
            observation_scopes_list=[None],
            text_signals_list=[""],
        )
    )[0]


@pytest.mark.postgres
async def test_postgres_migrations_and_native_regression(monkeypatch):
    url, schema = configure(monkeypatch, "postgres")
    try:
        migrate(url, schema, "postgres")
        migrate(url, schema, "postgres")
        raw = await asyncpg.connect(url)
        try:
            from hindsight_api.engine.db.postgresql import PostgresConnection
            from hindsight_api.engine.search.retrieval import retrieve_semantic_bm25_combined_sql

            conn = PostgresConnection(raw)
            await raw.execute(f"INSERT INTO {schema}.banks(bank_id) VALUES ('a')")
            await insert_fact(conn, "a", "A database stores meeting memories")
            result = await retrieve_semantic_bm25_combined_sql(
                conn,
                "[1,0,0]",
                "database",
                "a",
                ["world"],
                10,
            )
            assert result["world"].bm25
            assert result["world"].semantic
        finally:
            await raw.close()
    finally:
        drop_test_schema(url, schema)


@pytest.mark.lakebase
async def test_lakebase_lifecycle_search_isolation_and_rollback(monkeypatch):
    url, schema = configure(monkeypatch, "lakebase")
    try:
        migrate(url, schema, "lakebase")
        migrate(url, schema, "lakebase")
        raw = await asyncpg.connect(url)
        try:
            from hindsight_api.engine.db.postgresql import PostgresConnection
            from hindsight_api.engine.search.retrieval import retrieve_semantic_bm25_combined_sql

            from hindsight_lakebase import text

            conn = PostgresConnection(raw)
            await raw.execute(f"INSERT INTO {schema}.banks(bank_id) VALUES ('a'), ('b')")
            first = await insert_fact(conn, "a", "日本語検索を実装する")
            await insert_fact(conn, "a", "日本語検索とベクトル検索を検証する")
            await insert_fact(conn, "b", "日本語検索を実装する")
            await raw.execute(
                f"CREATE INDEX idx_memory_units_text_search ON {schema}.memory_units USING lakebase_bm25 (search_vector)"
            )
            # Force an inherited limit that used to cut candidates before caller filtering.
            await raw.execute("SET lakebase_bm25.default_limit = 1")
            result = await retrieve_semantic_bm25_combined_sql(conn, "[1,0,0]", "検索", "a", ["world"], 5)
            assert len(result["world"].bm25) == 2
            ids = [str(row.id) for row in result["world"].bm25]
            assert first in ids
            assert all(row.bm25_score > 0 for row in result["world"].bm25)
            # A tokenizer exception must abort both the insert and its projection.
            before = await raw.fetchval(f"SELECT count(*) FROM {schema}.memory_units")
            with monkeypatch.context() as patch:

                def fail(value):
                    raise ValueError("broken tokenizer")

                patch.setattr(text, "search_text", fail)
                with pytest.raises(ValueError, match="broken tokenizer"):
                    await insert_fact(conn, "a", "保存失敗")
            assert await raw.fetchval(f"SELECT count(*) FROM {schema}.memory_units") == before
            # Page IDs are bank-local strings, not globally unique UUIDs.
            for bank, title in [("a", "東京都の会議"), ("b", "大阪府の会議")]:
                async with text.write_scope(conn):
                    await raw.execute(
                        f"INSERT INTO {schema}.mental_models(bank_id,id,name,content,source_query) "
                        "VALUES ($1,'shared',$2,'日本語検索','test')",
                        bank,
                        title,
                    )
                    await text.refresh_rows(conn, f"{schema}.mental_models", bank, ["shared"])
            vectors = await raw.fetch(
                f"SELECT bank_id, search_vector::text AS vector FROM {schema}.mental_models ORDER BY bank_id"
            )
            assert "東京" in vectors[0]["vector"] and "大阪" not in vectors[0]["vector"]
            assert "大阪" in vectors[1]["vector"] and "東京" not in vectors[1]["vector"]
        finally:
            await raw.close()
        # Restart preserves the already-created BM25 index.
        migrate(url, schema, "lakebase")
        raw = await asyncpg.connect(url)
        try:
            assert await raw.fetchval("SELECT to_regclass($1)", f"{schema}.idx_memory_units_text_search")
        finally:
            await raw.close()
    finally:
        drop_test_schema(url, schema)

import uuid
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock

import pytest

from hindsight_lakebase import text, tokenizer


def test_tokenizer_japanese_and_custom(monkeypatch):
    sentence = "日本語検索を実装します。Lakebaseのデータベース"
    tokens = tokenizer.tokenize(sentence)
    assert "検索" in tokens and "日本語" in tokens and "lakebase" in tokens
    assert "検索" in tokenizer.tokenize("検索")
    assert tokenizer.tokenize(" 。！？\n") == []
    assert tokenizer.tokenize("") == []
    assert tokenizer.search_text(sentence, 2) == " ".join(tokens[:2])
    monkeypatch.setenv(tokenizer.ENV, "hindsight_lakebase.tokenizer:identity")
    assert tokenizer.search_text(sentence) == sentence


def test_tokenizer_invalid_output_is_not_fallback(monkeypatch):
    monkeypatch.setattr(tokenizer, "_load", lambda path: lambda value: [None])
    with pytest.raises(ValueError, match=r"list\[str\]"):
        tokenizer.search_text("原文")


@pytest.mark.parametrize("value", ["bad", "builtins:None", "builtins:does_not_exist"])
def test_invalid_tokenizer_fails(monkeypatch, value):
    monkeypatch.setenv(tokenizer.ENV, value)
    with pytest.raises((ValueError, AttributeError)):
        tokenizer.tokenize("test")


def test_backend_config_and_vector_dispatch(lakebase):
    from hindsight_api._vector_index import (
        ann_search_tuning_settings,
        index_using_clause,
        uses_per_bank_vector_indexes,
        validate_extension,
    )
    from hindsight_api.config import get_config

    assert get_config().text_search_extension == "lakebase_text"
    assert validate_extension("LAKEBASE_VECTOR") == "lakebase_vector"
    assert index_using_clause("lakebase_vector") == "USING lakebase_ann (embedding vector_cosine_ops)"
    assert uses_per_bank_vector_indexes("lakebase_vector")
    assert all(
        not key.startswith("hnsw.") for key, _ in ann_search_tuning_settings("lakebase_vector", kind="high_recall")
    )
    with pytest.raises(ValueError):
        validate_extension("lakebase-vector")


def test_sql_uses_bm25_preserves_filters_and_schema(lakebase, monkeypatch):
    from hindsight_api.engine.memory_engine import _current_schema
    from hindsight_api.engine.sql.postgresql import PostgreSQLDialect, knowledge_bm25_arm

    token = _current_schema.set("tenant_one")
    try:
        sql = PostgreSQLDialect().build_bm25_arm(
            table="tenant_one.memory_units",
            cols="id",
            fact_type="world",
            bank_id_param="$1",
            limit_param="$2",
            text_param="$3",
            tags_clause="AND tags @> $4",
            extra_where="AND updated_at > $5",
            text_search_extension="lakebase_text",
            bm25_min_score=0.5,
        )
        assert "USING" not in sql
        assert "to_tsvector('simple', $3)" in sql
        assert '"tenant_one"."idx_memory_units_text_search"' in sql
        assert "bank_id = $1" in sql and "fact_type = 'world'" in sql
        assert "AND tags @> $4" in sql and "AND updated_at > $5" in sql
        assert ">= 0.5" in sql and " ASC" in sql and "LIMIT $2" in sql
        page = knowledge_bm25_arm("lakebase_text", table_alias="mm", text_param="$3")
        assert '"tenant_one"."idx_mental_models_text_search"' in page.order_by
        assert page.match_filter.endswith("> 0")
        assert "検索" in PostgreSQLDialect().prepare_bm25_text([], "日本語検索", text_search_extension="lakebase_text")
        assert PostgreSQLDialect().prepare_bm25_text(["cat", "dog"], "cat dog") == "cat | dog"
    finally:
        _current_schema.reset(token)


class Connection:
    def __init__(self, rows=()):
        self.depth = 0
        self.rollbacks = 0
        self.fetch = AsyncMock(return_value=list(rows))
        self.fetchval = AsyncMock(return_value="existing_index")
        self.executemany = AsyncMock()
        self.execute = AsyncMock()

    @asynccontextmanager
    async def transaction(self):
        self.depth += 1
        try:
            yield self
        except BaseException:
            self.rollbacks += 1
            raise
        finally:
            self.depth -= 1


async def test_refresh_page_is_bank_scoped_and_preserves_source(lakebase):
    conn = Connection([{"id": "shared-id", "name": "日本語検索", "content": "東京都の会議"}])
    await text.refresh_rows(conn, "tenant.mental_models", "bank-a", ["shared-id"])
    query, bank, ids = conn.fetch.call_args.args
    assert "bank_id = $1" in query and "$2::text[]" in query
    assert bank == "bank-a" and ids == ["shared-id"]
    update, values = conn.executemany.call_args.args
    assert "SET search_vector" in update and "SET content" not in update
    assert "bank_id = $1 AND id = $2::text" in update
    assert values[0][:2] == ("bank-a", "shared-id")
    assert "日本語 検索" in values[0][2]


async def test_native_writes_have_no_extra_transaction_or_projection():
    conn = Connection()

    @text.indexed_write
    async def write(conn):
        assert conn.depth == 0
        await text.refresh_rows(conn, "public.memory_units", "a", [uuid.uuid4()])
        return "native"

    assert await write(conn) == "native"
    conn.fetch.assert_not_called()
    conn.executemany.assert_not_called()


async def test_upstream_batch_writer_keeps_raw_text_and_propagates_tokenizer_failure(lakebase, monkeypatch):
    from hindsight_api.engine.db.ops_postgresql import PostgreSQLOps

    unit_id = uuid.uuid4()
    raw = "日本語検索を実装する"
    conn = Connection()
    conn.fetch.side_effect = [[{"id": unit_id}], [{"id": unit_id, "text": raw, "context": "会議", "text_signals": ""}]]
    kwargs = dict(
        bank_id="bank",
        fact_texts=[raw],
        embeddings=["[1,0,0]"],
        event_dates=[None],
        occurred_starts=[None],
        occurred_ends=[None],
        mentioned_ats=[None],
        contexts=["会議"],
        fact_types=["world"],
        metadata_jsons=["{}"],
        chunk_ids=[None],
        document_ids=[None],
        tags_list=["[]"],
        observation_scopes_list=[None],
        text_signals_list=[""],
        attachment_ids_list=["[]"],
        text_search_extension="lakebase_text",
    )
    assert await PostgreSQLOps().insert_facts_batch(conn, **kwargs) == [str(unit_id)]
    assert conn.fetch.call_args_list[0].args[2] == [raw]
    assert "日本語 検索" in conn.executemany.call_args.args[1][0][2]
    assert conn.depth == 0
    conn.fetch.side_effect = [[{"id": unit_id}], [{"id": unit_id, "text": raw, "context": "", "text_signals": ""}]]
    monkeypatch.setattr(text, "search_text", lambda value: (_ for _ in ()).throw(ValueError("tokenizer failed")))
    with pytest.raises(ValueError, match="tokenizer failed"):
        await PostgreSQLOps().insert_facts_batch(conn, **kwargs)
    assert conn.rollbacks == 1


async def test_search_scope_sets_budget_without_ddl(lakebase):
    conn = Connection()
    async with text.search_scope(conn, 123):
        assert conn.depth == 1
    conn.fetchval.assert_not_called()
    assert ("SELECT set_config('lakebase_bm25.default_limit', $1, true)", "123") in [
        call.args for call in conn.execute.call_args_list
    ]
    assert not any("CREATE" in call.args[0] for call in conn.execute.call_args_list)
    assert conn.depth == 0


@pytest.mark.parametrize("backend", ["native", "lakebase_text"])
@pytest.mark.parametrize("query", ["日本語検索", ""])
async def test_upstream_recall_uses_release_signature(monkeypatch, backend, query):
    from hindsight_api.engine.search.retrieval import retrieve_semantic_bm25_combined_sql

    monkeypatch.setenv("HINDSIGHT_API_TEXT_SEARCH_EXTENSION", backend)
    conn = Connection()
    active = backend == "lakebase_text" and bool(query)

    async def fetch(sql, *params):
        assert conn.depth == int(active)
        assert params[:2] == ("[1,0,0]", "bank")
        if active:
            assert "日本語 検索" in params[3]
        return []

    conn.fetch.side_effect = fetch
    result = await retrieve_semantic_bm25_combined_sql(conn, "[1,0,0]", query, "bank", ["world"], 10)
    assert result["world"].semantic == [] and result["world"].bm25 == []
    conn.fetch.assert_awaited_once()
    assert conn.execute.call_count == (2 if active else 0)
    assert conn.depth == 0


async def test_upstream_edit_reindexes_locked_current_row(lakebase):
    from hindsight_api.engine.memories.pg.writes import apply_edit

    unit = uuid.uuid4()
    conn = Connection([{"id": unit, "text": "検索方式を変更", "context": "東京", "text_signals": "索引"}])
    await apply_edit(
        conn=conn,
        fq_table=lambda name: f"public.{name}",
        bank_id="bank",
        unit_id=str(unit),
        text="検索方式を変更",
        context="東京",
        fact_type="world",
        occurred_start=None,
        occurred_end=None,
        event_date=None,
        mentioned_at=None,
        entity_ids=None,
    )
    assert conn.depth == 0
    assert "検索" in conn.executemany.call_args.args[1][0][2]
    assert "索引" in conn.executemany.call_args.args[1][0][2]
    assert conn.execute.call_args_list[0].args[3] == "検索方式を変更"


async def test_upstream_restore_tokenizer_failure_aborts_restore(lakebase, monkeypatch):
    from hindsight_api.engine.memories.pg import writes

    unit = uuid.uuid4()
    conn = Connection([{"id": unit, "text": "復元する内容", "context": "", "text_signals": ""}])
    conn.fetchrow = AsyncMock(return_value={"id": unit})
    monkeypatch.setattr(writes, "_archive_columns", AsyncMock(return_value="id, bank_id, text"))

    def fail(value):
        raise ValueError("tokenizer failed")

    monkeypatch.setattr(text, "search_text", fail)
    with pytest.raises(ValueError, match="tokenizer failed"):
        async with conn.transaction():
            await writes.restore_memory(
                conn=conn, fq_table=lambda name: f"public.{name}", bank_id="a", unit_id=str(unit)
            )
    assert "INSERT INTO" in conn.execute.call_args_list[0].args[0]
    assert conn.rollbacks == 1


async def test_upstream_observation_creation_uses_projection(lakebase, monkeypatch):
    from types import SimpleNamespace

    from hindsight_api.engine.consolidation import consolidator

    conn = Connection()
    conn.fetchrow = AsyncMock(return_value={"id": uuid.uuid4()})
    conn.fetch.return_value = [{"id": uuid.uuid4(), "text": "日本語検索の観察", "context": "", "text_signals": ""}]
    monkeypatch.setattr(consolidator, "get_memories", lambda: SimpleNamespace(store_owned_for=lambda bank: False))
    monkeypatch.setattr(consolidator, "_filter_live_source_memories", AsyncMock(return_value=[uuid.uuid4()]))
    engine = SimpleNamespace(_backend=SimpleNamespace(ops=SimpleNamespace(uses_observation_sources_table=False)))

    async def write(*args):
        assert conn.depth == 1

    conn.executemany.side_effect = write
    # The consolidation batch owns the transaction; the projection must join it.
    async with conn.transaction():
        result = await consolidator._apply_create_observation(
            conn, engine, "a", [uuid.uuid4()], "日本語検索の観察", "[1,0,0]"
        )
    assert result["action"] == "created"
    assert conn.fetchrow.call_args.args[3] == "日本語検索の観察"
    assert "日本語 検索" in conn.executemany.call_args.args[1][0][2]


async def test_upstream_page_creation_uses_projection(lakebase):
    from types import SimpleNamespace

    from hindsight_api.engine.memory_engine import MemoryEngine

    conn = Connection([{"id": "page", "name": "会議検索", "content": "日本語の内容"}])
    conn.fetchrow = AsyncMock(return_value={"id": "page"})
    engine = SimpleNamespace(_pg_carries_page_search=lambda bank: True)
    await MemoryEngine._insert_pinned_mental_model(
        engine,
        conn,
        mental_model_id="page",
        bank_id="a",
        name="会議検索",
        source_query="test",
        content="日本語の内容",
        embedding="[1,0,0]",
        tags=[],
        max_tokens=None,
        trigger=None,
    )
    assert conn.executemany.call_args.args[1][0][:2] == ("a", "page")


async def test_shared_import_writer_is_atomic_and_bank_scoped(lakebase, monkeypatch):
    from hindsight_api.engine.transfer.importer import _restore_rows

    conn = Connection()
    rows = [
        {"bank_id": "a", "id": "same", "name": "日本語検索", "content": "東京"},
        {"bank_id": "b", "id": "same", "name": "会議検索", "content": "大阪"},
    ]
    conn.fetch.side_effect = [
        [{"column_name": col, "data_type": "text"} for col in rows[0]],
        [rows[0]],
        [rows[1]],
    ]

    async def assert_transaction(*args):
        assert conn.depth == 1

    conn.execute.side_effect = assert_transaction
    conn.executemany.side_effect = assert_transaction
    assert await _restore_rows(conn, "mental_models", rows) == 2
    assert conn.executemany.call_args_list[0].args[1][0][:2] == ("a", "same")
    assert conn.executemany.call_args_list[1].args[1][0][:2] == ("b", "same")
    assert "FOR UPDATE" in conn.fetch.call_args.args[0]

    conn.fetch.side_effect = [
        [{"column_name": col, "data_type": "text"} for col in rows[0]],
        [rows[0]],
    ]

    def fail(value):
        raise ValueError("tokenizer failed")

    monkeypatch.setattr(text, "search_text", fail)
    with pytest.raises(ValueError, match="tokenizer failed"):
        await _restore_rows(conn, "mental_models", rows[:1])
    assert conn.rollbacks == 1


@pytest.mark.parametrize("backend", ["native", "vchord", "pg_textsearch", "pgroonga", "pg_search"])
async def test_other_text_backends_never_tokenize_or_start_lakebase_transactions(monkeypatch, backend):
    monkeypatch.setenv("HINDSIGHT_API_TEXT_SEARCH_EXTENSION", backend)
    monkeypatch.setenv("HINDSIGHT_API_VECTOR_EXTENSION", "lakebase_vector")
    monkeypatch.setenv(tokenizer.ENV, "does_not_exist:tokenize")
    conn = Connection()
    async with text.write_scope(conn), text.search_scope(conn, 5):
        assert conn.depth == 0
        await text.refresh_rows(conn, "memory_units", "a", [uuid.uuid4()])
    conn.fetch.assert_not_called()
    conn.execute.assert_not_called()
    conn.executemany.assert_not_called()


async def test_vector_health_accepts_lakebase_indexes(lakebase):
    from hindsight_api.engine.vector_index_health import _index_health

    conn = Connection()

    async def catalog(query, schema, names, methods, predicate, bank_id):
        assert schema == "tenant" and bank_id == "bank"
        assert "fact_type" in predicate
        return [{"index_name": names[0], "healthy": "lakebase_ann" in methods}]

    conn.fetch.side_effect = catalog
    assert await _index_health(conn, "tenant", ["idx_mu_emb_worl_0123456789abcdef"], "bank") == {
        "idx_mu_emb_worl_0123456789abcdef": True,
    }


@pytest.mark.parametrize("backend", ["native", "lakebase_text"])
async def test_upstream_page_rename_refreshes_projection_atomically(monkeypatch, backend):
    from types import SimpleNamespace

    from hindsight_api.engine import memory_engine

    monkeypatch.setenv("HINDSIGHT_API_TEXT_SEARCH_EXTENSION", backend)
    conn = Connection([{"id": "page", "name": "日本語検索", "content": "会議"}])
    row = {"id": "page", "name": "日本語検索", "content": "会議", "reflect_response": None}
    conn.fetchrow = AsyncMock(return_value=row)

    async def write(*args):
        assert conn.depth == 1

    conn.executemany.side_effect = write
    engine = SimpleNamespace(
        _authenticate_tenant=AsyncMock(),
        _operation_validator=None,
        _get_backend=AsyncMock(),
        _mental_model_embedding_vector=AsyncMock(return_value=[1.0, 0.0, 0.0]),
        _pg_carries_page_search=lambda bank: True,
        _index_knowledge_page=AsyncMock(),
        _row_to_mental_model=lambda value: value,
    )

    # Knowledge-node renames reuse update_mental_model on the caller's connection.
    async def rename():
        return await memory_engine.MemoryEngine.update_mental_model(
            engine, "bank", "page", name="日本語検索", conn=conn, request_context=None
        )

    assert await rename() == row
    if backend == "lakebase_text":
        assert conn.executemany.call_args.args[1] == [("bank", "page", "日本語 検索 会議")]
        with monkeypatch.context() as patch:

            def fail(value):
                raise ValueError("tokenizer failed")

            patch.setattr(text, "search_text", fail)
            with pytest.raises(ValueError, match="tokenizer failed"):
                await rename()
        assert conn.rollbacks == 1
        assert await rename() == row
    else:
        conn.fetch.assert_not_called()
        conn.executemany.assert_not_called()
    assert conn.depth == 0

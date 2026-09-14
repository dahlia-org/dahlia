"""Lakebase BM25 SQL and transactional projection writes."""

from contextlib import asynccontextmanager

from .tokenizer import search_text

TABLES = {"memory_units": ("text", "context", "text_signals"), "mental_models": ("name", "content")}


def enabled() -> bool:
    from hindsight_api.config import get_config

    return get_config().text_search_extension == "lakebase_text"


def quoted(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def index_name(table: str) -> str:
    # table comes from Hindsight's fq_table(), never from request text.
    from hindsight_api.engine.memory_engine import get_current_schema

    name = table.rsplit(".", 1)[-1].strip('"')
    if name not in TABLES:
        raise ValueError(f"Unsupported search table: {name}")
    schema = table.rsplit(".", 1)[0].strip('"') if "." in table else (get_current_schema() or "public")
    return f"{quoted(schema)}.{quoted('idx_' + name + '_text_search')}"


def distance(column: str, parameter: str, index: str) -> str:
    literal = index.replace("'", "''")
    return f"{column} <@> public.to_bm25query(to_tsvector('simple', {parameter}), '{literal}'::regclass)"


@asynccontextmanager
async def write_scope(conn):
    """Keep source writes and their Python-tokenized projection atomic."""
    if not enabled():
        yield
        return
    async with conn.transaction():
        yield


async def refresh_rows(conn, table: str, bank_id: str, ids):
    """Called inside the source write's transaction, after its row locks are held."""
    if not enabled() or not ids:
        return
    name = table.rsplit(".", 1)[-1].strip('"')
    columns = TABLES[name]
    id_type = "text" if name == "mental_models" else "uuid"
    rows = await conn.fetch(
        f"SELECT id, {', '.join(columns)} FROM {table} WHERE bank_id = $1 AND id = ANY($2::{id_type}[]) FOR UPDATE",
        bank_id,
        list(ids),
    )
    values = [(bank_id, row["id"], search_text(" ".join(row[col] or "" for col in columns))) for row in rows]
    await conn.executemany(
        f"UPDATE {table} SET search_vector = to_tsvector('simple', $3::text) WHERE bank_id = $1 AND id = $2::{id_type}",
        values,
    )


def indexed_write(function):
    """Apply the shared transaction boundary to connection-based writers."""
    import inspect
    from functools import wraps

    signature = inspect.signature(function)

    @wraps(function)
    async def wrapped(*args, **kwargs):
        if not enabled():
            return await function(*args, **kwargs)
        bound = signature.bind(*args, **kwargs)
        async with write_scope(bound.arguments["conn"]):
            return await function(*args, **kwargs)

    return wrapped


@asynccontextmanager
async def search_scope(conn, limit: int, *, active: bool = True):
    if not active or not enabled():
        yield
        return
    async with conn.transaction():
        await conn.execute("SELECT set_config('lakebase_bm25.prefilter', 'on', true)")
        await conn.execute("SELECT set_config('lakebase_bm25.default_limit', $1, true)", str(max(1, limit)))
        yield


def indexed_search(function):
    import inspect
    from functools import wraps

    signature = inspect.signature(function)

    @wraps(function)
    async def wrapped(*args, **kwargs):
        if not enabled():
            return await function(*args, **kwargs)
        bound = signature.bind(*args, **kwargs)
        bound.apply_defaults()
        from hindsight_api.engine.search.retrieval import tokenize_query

        if not tokenize_query(bound.arguments["query_text"]):
            return await function(*args, **kwargs)
        async with search_scope(bound.arguments["conn"], bound.arguments["limit"]):
            return await function(*bound.args, **bound.kwargs)

    return wrapped


def indexed_import(function):
    """Attach the projection to the shared archive row writer, before commit."""
    from collections import defaultdict
    from functools import wraps

    @wraps(function)
    async def wrapped(conn, table, rows, **kwargs):
        if table != "mental_models" or not rows or not enabled():
            return await function(conn, table, rows, **kwargs)
        from hindsight_api.engine.schema import fq_table

        async with conn.transaction():
            result = await function(conn, table, rows, **kwargs)
            by_bank = defaultdict(list)
            for row in rows:
                by_bank[row["bank_id"]].append(row["id"])
            for bank, ids in by_bank.items():
                await refresh_rows(conn, fq_table(table), bank, ids)
            return result

    return wrapped

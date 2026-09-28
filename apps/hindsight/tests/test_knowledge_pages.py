"""Synthetic checks of the pinned refresh and provenance API, no live LLM or bank."""

from datetime import UTC, datetime
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

from hindsight_api import MemoryEngine, RequestContext
from hindsight_api.engine.memories.pg.curation import get_memory_unit
from hindsight_api.engine.response_models import MemoryFact, ReflectResult


async def test_refresh_records_database_cutoff_and_effective_generation_settings(monkeypatch):
    monkeypatch.setenv("HINDSIGHT_API_LLM_PROVIDER", "mock")
    engine = MemoryEngine(
        skip_llm_verification=True, embeddings=MagicMock(), cross_encoder=MagicMock(), query_analyzer=MagicMock()
    )
    cutoff = datetime(2026, 1, 1, tzinfo=UTC)
    engine._mental_model_refresh_cutoff = AsyncMock(return_value=cutoff)
    engine._mental_model_scope_watermark = AsyncMock(
        return_value=SimpleNamespace(newest_in_scope=cutoff, watermark=cutoff)
    )
    engine.reflect_async = AsyncMock(
        return_value=ReflectResult(
            text="Synthetic hypothesis",
            based_on={"world": [MemoryFact(id="synthetic-fact", text="Synthetic evidence", fact_type="world")]},
        )
    )
    model = {
        "id": "workspace-insights",
        "name": "Cross-meeting insights",
        "source_query": "Synthetic query",
        "tags": [],
        "max_tokens": 2048,
        "trigger": {
            "mode": "full",
            "exclude_mental_models": True,
            "reflect_search_observations_include_entities": False,
        },
    }
    result = await engine._execute_mental_model_refresh(
        "synthetic-bank", model, request_context=RequestContext(), operation_label="refresh_mental_model"
    )
    assert result.reflect_response["dahlia_generation"] == {
        "cutoff": cutoff.isoformat(),
        "source_query": model["source_query"],
        "tags": [],
        "max_tokens": 2048,
        "trigger": model["trigger"],
    }
    assert result.reflect_response["based_on"]["world"][0]["id"] == "synthetic-fact"
    assert engine.reflect_async.call_args.kwargs["created_before"] == cutoff
    assert engine.reflect_async.call_args.kwargs["exclude_mental_models"] is True
    assert engine.reflect_async.call_args.kwargs["reflect_search_observations_include_entities_override"] is False


async def test_fact_detail_exposes_mutation_time_and_uses_the_requested_bank():
    instant = datetime(2026, 1, 1, tzinfo=UTC)
    row = dict.fromkeys(
        "id text context event_date occurred_start occurred_end mentioned_at fact_type document_id chunk_id tags metadata "
        "source_memory_ids observation_scopes edited_at invalidation_reason invalidated_at".split()
    )
    row.update(id="synthetic-fact", text="Synthetic evidence", fact_type="world", updated_at=instant)
    connection = MagicMock()
    connection.fetchrow = AsyncMock(return_value=row)
    connection.fetch = AsyncMock(return_value=[])
    result = await get_memory_unit(
        conn=connection, ops=MagicMock(), fq_table=lambda name: name, bank_id="expected-bank", unit_id="synthetic-fact"
    )
    assert result["type"] == "world"
    assert result["updated_at"] == instant.isoformat()
    assert result["state"] == "valid"
    query, unit, bank = connection.fetchrow.call_args.args
    assert "updated_at" in query and "bank_id = $2" in query
    assert (unit, bank) == ("synthetic-fact", "expected-bank")

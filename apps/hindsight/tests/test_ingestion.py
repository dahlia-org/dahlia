"""Phase 4 contracts against the pinned provider/engine; only synthetic content."""

from dataclasses import replace
from unittest.mock import AsyncMock

import httpx
import pytest
from hindsight_api import MemoryEngine, RequestContext
from hindsight_api.config import HindsightConfig
from hindsight_api.engine.llm_interface import ProviderContentPolicyError
from hindsight_api.engine.memory_engine import _is_non_retryable_task_error
from hindsight_api.engine.providers.openai_compatible_llm import OpenAICompatibleLLM

from hindsight_lakebase.databricks import DatabricksOAuthTokenProvider
from hindsight_lakebase.ingestion import ingestion_policy, operation_error_code


def test_policy_tracks_effective_settings_without_credentials():
    config = HindsightConfig.from_env()
    first = ingestion_policy(config)
    assert ingestion_policy(replace(config, llm_api_key="SECRET", retain_llm_api_key="OTHER")) == first
    for changes in (
        {"retain_extraction_mode": "verbose"},
        {"retain_chunk_batch_size": config.retain_chunk_batch_size + 1},
        {"retain_max_attachments_per_chunk": config.retain_max_attachments_per_chunk + 1},
        {"retain_mission": "Different mission"},
        {"retain_llm_model": "system.ai.synthetic"},
        {"entities_allow_free_form": False},
        {"retain_strategies": {"test": {"retain_chunk_size": 123}}, "retain_default_strategy": "test"},
    ):
        assert ingestion_policy(replace(config, **changes)) != first
    strategy = replace(
        config, retain_strategies={"test": {"retain_extraction_mode": "verbose"}}, retain_default_strategy="test"
    )
    from hindsight_api.config_resolver import apply_strategy

    assert ingestion_policy(strategy) == ingestion_policy(
        apply_strategy(strategy, "test"), strategy="test", applied=True
    )
    assert ingestion_policy(replace(config, retain_strategies={"unused": {"retain_chunk_size": 123}})) == first


@pytest.mark.parametrize("mode", ["text", "structured", "tools"])
async def test_databricks_policy_200_is_permanent_and_never_an_answer(monkeypatch, mode):
    monkeypatch.setenv("DATABRICKS_HOST", "https://workspace.example")
    monkeypatch.setenv("DATABRICKS_CLIENT_ID", "synthetic")
    monkeypatch.setenv("DATABRICKS_CLIENT_SECRET", "synthetic")
    monkeypatch.setattr(DatabricksOAuthTokenProvider, "get_token_async", AsyncMock(return_value="synthetic"))
    provider = OpenAICompatibleLLM(provider="databricks", model="system.ai.gpt-6-luna", api_key=None, base_url=None)
    requests = []

    def respond(request):
        requests.append(request)
        return httpx.Response(
            200,
            json={
                "id": "synthetic",
                "object": "chat.completion",
                "created": 0,
                "model": "synthetic",
                "databricks_service_policy": {"reason": "SECRET POLICY REASON"},
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "SECRET BLOCK TEXT"},
                        "finish_reason": "stop",
                    }
                ],
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
        monkeypatch.setattr(provider._client, "_client", client)
        args = {"messages": [{"role": "user", "content": "synthetic"}], "max_retries": 3}
        with pytest.raises(ProviderContentPolicyError, match="^memory_policy_blocked$") as error:
            if mode == "tools":
                await provider.call_with_tools(**args, tools=[])
            elif mode == "structured":
                from pydantic import BaseModel

                class Answer(BaseModel):
                    text: str

                await provider.call(**args, response_format=Answer)
            else:
                await provider.call(**args)
        assert len(requests) == 1
        assert _is_non_retryable_task_error(error.value)
        assert (
            operation_error_code({"error_message": f"ProviderContentPolicyError: {error.value}"})
            == "memory_policy_blocked"
        )
        assert "SECRET" not in str(error.value)


async def test_reprocess_preserves_caller_operation_id_and_forces_extraction():
    engine = object.__new__(MemoryEngine)
    engine._authenticate_tenant = AsyncMock()
    engine._operation_validator = None
    engine.get_document = AsyncMock(
        return_value={
            "original_text": "synthetic content",
            "retain_params": {"metadata": {"source_revision": "2"}, "strategy": "standard"},
            "tags": ["project:synthetic"],
        }
    )
    engine.submit_async_retain = AsyncMock(return_value={"operation_id": "synthetic-operation"})
    context = RequestContext()
    await engine.reprocess_document(
        "synthetic", "document", request_context=context, operation_id="synthetic-operation"
    )
    call = engine.submit_async_retain.call_args
    assert call.kwargs["operation_id"] == "synthetic-operation"
    assert call.kwargs["strategy"] == "standard"
    assert call.args[1][0]["force_reextract"] is True
    assert call.args[1][0]["metadata"] == {"source_revision": "2"}


def test_policy_error_discriminator_ignores_unrelated_failures():
    assert operation_error_code({"error_message": "timeout"}) is None
    assert (
        operation_error_code({"error_message": "ProviderContentPolicyError: memory_policy_blocked (2 tasks)"})
        == "memory_policy_blocked"
    )


def test_each_subbatch_checks_expected_policy_and_entity_boundary():
    from hindsight_lakebase.ingestion import IngestionConfigChangedError, stamp_ingestion

    config = replace(HindsightConfig.from_env(), entities_allow_free_form=False, entity_labels=[])
    expected = ingestion_policy(config)
    items = [
        {"content": "synthetic", "metadata": {"source_kind": "shared", "dahlia_expected_ingestion_policy": expected}}
    ]
    stamped = stamp_ingestion(items, config, None)
    assert stamped[0]["metadata"]["dahlia_ingestion_policy"] == expected
    assert "dahlia_ingestion_policy" not in items[0]["metadata"]
    for changed in (replace(config, retain_extraction_mode="verbose"), replace(config, entities_allow_free_form=True)):
        with pytest.raises(IngestionConfigChangedError) as error:
            stamp_ingestion(items, changed, None)
        assert _is_non_retryable_task_error(error.value)


def test_sync_refusal_exposes_only_fixed_http_code():
    from hindsight_api.api.http import _internal_error

    error = _internal_error(ProviderContentPolicyError("memory_policy_blocked"), "synthetic")
    assert error.status_code == 422
    assert error.detail == "memory_policy_blocked"
    assert error.headers == {"x-dahlia-memory-error": "memory_policy_blocked"}


@pytest.mark.parametrize("probe", [False, True])
async def test_databricks_embedding_refusal_is_permanent_and_safe(monkeypatch, probe, caplog):
    from hindsight_api.engine.embeddings import DatabricksEmbeddings
    from openai import AsyncOpenAI

    monkeypatch.setenv("DATABRICKS_HOST", "https://workspace.example")
    monkeypatch.setenv("DATABRICKS_CLIENT_ID", "synthetic")
    monkeypatch.setenv("DATABRICKS_CLIENT_SECRET", "synthetic")
    monkeypatch.setattr(DatabricksOAuthTokenProvider, "get_token_async", AsyncMock(return_value="synthetic"))
    requests = []

    def respond(request):
        requests.append(request)
        return httpx.Response(
            200,
            json={
                "databricks_service_policy": {"reason": "SECRET POLICY REASON"},
                "choices": [{"message": {"content": "SECRET BLOCK TEXT"}}],
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as http:
        client = AsyncOpenAI(api_key="synthetic", base_url="https://workspace.example/v1", http_client=http)
        monkeypatch.setattr("openai.AsyncOpenAI", lambda **_: client)
        provider = DatabricksEmbeddings(model="synthetic", dimensions=None if probe else 3)
        with pytest.raises(ProviderContentPolicyError, match="^memory_policy_blocked$") as error:
            await provider.initialize()
            await provider.encode(["synthetic"])
        assert len(requests) == 1
        assert _is_non_retryable_task_error(error.value)
        assert (
            operation_error_code({"error_message": f"ProviderContentPolicyError: {error.value}"})
            == "memory_policy_blocked"
        )
        assert "SECRET" not in str(error.value)
        assert "SECRET" not in caplog.text

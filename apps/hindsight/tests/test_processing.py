"""Exercise the pinned upstream processing boundaries without live customer data."""

import asyncio
import json
import logging
import os
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

import httpx
import pytest
from hindsight_api import MemoryEngine, RequestContext
from hindsight_api.config import clear_config_cache
from hindsight_api.engine.reflect.agent import run_reflect_agent
from hindsight_api.engine.response_models import LLMCallResult, LLMToolCall, LLMToolCallResult, TokenUsage

from hindsight_lakebase import reranker
from hindsight_lakebase.databricks import DatabricksOAuthTokenProvider

SCHEMA = {
    "type": "object",
    "properties": {"claims": {"type": "array", "items": {"type": "string"}}},
    "required": ["claims"],
}


def test_reranker_uses_immutable_snapshot(monkeypatch):
    import huggingface_hub

    download = MagicMock(return_value="/cache/pinned-model")
    monkeypatch.setattr(huggingface_hub, "snapshot_download", download)
    monkeypatch.setenv("HINDSIGHT_API_RERANKER_PROVIDER", "local")
    monkeypatch.setenv("HINDSIGHT_API_RERANKER_LOCAL_MODEL", reranker.MODEL)
    reranker.prepare_reranker()
    assert len(reranker.REVISION) == 40
    assert download.call_args.kwargs["revision"] == reranker.REVISION
    assert download.call_args.kwargs["repo_id"] == reranker.MODEL
    assert os.environ["HINDSIGHT_API_RERANKER_LOCAL_MODEL"] == "/cache/pinned-model"
    reranker.prepare_reranker()
    download.assert_called_once()


@pytest.mark.parametrize("overrides", [False, True])
async def test_processing_llms_use_standard_settings_and_oauth(monkeypatch, overrides):
    for name, value in {
        "DATABRICKS_HOST": "https://workspace.example",
        "DATABRICKS_CLIENT_ID": "synthetic-client",
        "DATABRICKS_CLIENT_SECRET": "synthetic-secret",
        "HINDSIGHT_API_LLM_PROVIDER": "databricks",
        "HINDSIGHT_API_LLM_MODEL": "system.ai.gpt-6-luna",
    }.items():
        monkeypatch.setenv(name, value)
    operations = ("RETAIN", "REFLECT", "CONSOLIDATION", "MENTAL_MODEL_REFRESH")
    for operation in operations:
        for field in ("PROVIDER", "MODEL"):
            monkeypatch.delenv(f"HINDSIGHT_API_{operation}_LLM_{field}", raising=False)
        if overrides:
            monkeypatch.setenv(f"HINDSIGHT_API_{operation}_LLM_PROVIDER", "databricks")
            monkeypatch.setenv(f"HINDSIGHT_API_{operation}_LLM_MODEL", f"system.ai.test-{operation.lower()}")
    token = AsyncMock(return_value="synthetic-oauth-token")
    monkeypatch.setattr(DatabricksOAuthTokenProvider, "get_token_async", token)
    clear_config_cache()
    engine = MemoryEngine(
        skip_llm_verification=True, embeddings=MagicMock(), cross_encoder=MagicMock(), query_analyzer=MagicMock()
    )
    requests = []

    def respond(request):
        assert request.url.host == "workspace.example"
        assert request.headers["authorization"] == "Bearer synthetic-oauth-token"
        assert "x-forwarded-access-token" not in request.headers
        body = json.loads(request.content)
        requests.append(body)
        content = json.dumps({"claims": ["synthetic hypothesis"]}) if "response_format" in body else "synthetic answer"
        return httpx.Response(
            200,
            json={
                "id": "synthetic",
                "object": "chat.completion",
                "created": 0,
                "model": body["model"],
                "choices": [
                    {"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}
                ],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            },
        )

    providers = [getattr(engine, f"_{operation.lower()}_llm_config") for operation in operations]
    clients = []
    for identity in dict.fromkeys(id(p) for p in providers):
        llm = next(p for p in providers if id(p) == identity)
        client = httpx.AsyncClient(transport=httpx.MockTransport(respond))
        clients.append(client)
        monkeypatch.setattr(llm._provider_impl._client, "_client", client)
    try:
        for operation, llm in zip(operations, providers):
            await llm.call(
                messages=[{"role": "user", "content": "synthetic input"}], scope=operation.lower(), max_retries=0
            )
            assert requests[-1]["model"] == (
                f"system.ai.test-{operation.lower()}" if overrides else "system.ai.gpt-6-luna"
            )
        engine._authenticate_tenant = AsyncMock()
        engine.get_mental_model = AsyncMock(return_value={"trigger": {"response_schema": SCHEMA}, "max_tokens": 128})
        engine._execute_mental_model_refresh = AsyncMock(
            return_value=SimpleNamespace(
                reflect_response={},
                outcome="content_written",
                final_content="synthetic answer",
                final_structured=None,
                source_query="synthetic query",
                processed_watermark=None,
            )
        )
        engine.update_mental_model = AsyncMock()
        await engine.refresh_mental_model("synthetic-bank", "synthetic-model", request_context=RequestContext())
        assert requests[-1]["model"] == ("system.ai.test-mental_model_refresh" if overrides else "system.ai.gpt-6-luna")
        assert engine.update_mental_model.call_args.kwargs["reflect_response"]["structured_output"] == {
            "claims": ["synthetic hypothesis"]
        }
        assert token.await_count == len(requests) >= 5
    finally:
        for client in clients:
            await client.aclose()


@pytest.mark.parametrize("startup_failure", [False, True])
def test_upstream_success_failure_and_startup_logs_never_emit_content(startup_failure):
    result = subprocess.run(
        [sys.executable, __file__, str(startup_failure)], capture_output=True, text=True, timeout=90
    )
    assert result.returncode == int(startup_failure), result.stderr[-2000:]
    assert "DAHLIA_PRIVATE_MARKER" not in result.stdout + result.stderr
    records = [json.loads(line) for line in result.stderr.splitlines() if line.startswith("{")]
    assert records and any(record["severity"] == "ERROR" for record in records)
    assert all(set(record) == {"severity", "timestamp", "logger"} for record in records)


def test_database_bootstrap_does_not_print_connection_errors():
    env = {
        **os.environ,
        "PGHOST": "localhost",
        "PGDATABASE": "synthetic",
        "PGUSER": "synthetic",
        "PGPASSWORD": "DAHLIA_PRIVATE_MARKER_PASSWORD",
        "PGPORT": "DAHLIA_PRIVATE_MARKER_INVALID_PORT",
    }
    result = subprocess.run(
        [sys.executable, "scripts/start_databricks.py"], env=env, capture_output=True, text=True, timeout=30
    )
    assert result.returncode == 1
    assert "DAHLIA_PRIVATE_MARKER" not in result.stdout + result.stderr
    assert "Hindsight database startup failed" in result.stderr


async def exercise_logs():
    for fail in (False, True):
        llm = MagicMock()
        llm._provider_impl = None
        llm.call_with_tools = AsyncMock(
            side_effect=[
                LLMToolCallResult(
                    tool_calls=[LLMToolCall(id="1", name="recall", arguments={"query": "DAHLIA_PRIVATE_MARKER_QUERY"})],
                    finish_reason="tool_calls",
                ),
                LLMToolCallResult(
                    tool_calls=[
                        LLMToolCall(
                            id="2",
                            name="done",
                            arguments={"answer": "DAHLIA_PRIVATE_MARKER_ANSWER", "memory_ids": ["fact"]},
                        )
                    ],
                    finish_reason="tool_calls",
                ),
            ]
        )
        llm.call = AsyncMock(
            return_value=LLMCallResult(content={"claims": ["DAHLIA_PRIVATE_MARKER_CLAIM"]}, usage=TokenUsage())
        )
        if fail:
            llm.call.side_effect = RuntimeError("DAHLIA_PRIVATE_MARKER_PROVIDER_SECRET")
        result = await run_reflect_agent(
            llm_config=llm,
            bank_id="synthetic",
            query="DAHLIA_PRIVATE_MARKER_QUERY",
            bank_profile={"name": "synthetic", "mission": "fixed"},
            include_observations=False,
            max_iterations=4,
            response_schema=SCHEMA,
            search_mental_models_fn=AsyncMock(),
            search_observations_fn=AsyncMock(),
            recall_fn=AsyncMock(return_value={"memories": [{"id": "fact", "content": "DAHLIA_PRIVATE_MARKER_TOOL"}]}),
            expand_fn=AsyncMock(),
        )
        assert result.text == "DAHLIA_PRIVATE_MARKER_ANSWER"
        assert bool(result.structured_output_error) is fail
    provider = DatabricksOAuthTokenProvider(
        "https://synthetic.example",
        "synthetic",
        "DAHLIA_PRIVATE_MARKER_SECRET",
        opener=MagicMock(side_effect=OSError("DAHLIA_PRIVATE_MARKER_OAUTH_ERROR")),
    )
    try:
        provider.get_token()
    except RuntimeError:
        logging.getLogger("uvicorn.error").exception("DAHLIA_PRIVATE_MARKER_EXCEPTION")


if __name__ == "__main__":
    import hindsight_api.main

    from hindsight_lakebase import server

    def serve():
        asyncio.run(exercise_logs())
        if sys.argv[-1] == "True":
            raise RuntimeError("DAHLIA_PRIVATE_MARKER_STARTUP")

    hindsight_api.main.main = serve
    server.main()

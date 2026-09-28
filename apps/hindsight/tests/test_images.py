"""Image contracts use synthetic pixels and mocked provider transport only."""

import hashlib
import json
import logging
from dataclasses import replace
from datetime import datetime
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest
from hindsight_api.config import HindsightConfig, JsonFormatter
from hindsight_api.engine.providers.openai_compatible_llm import OpenAICompatibleLLM
from hindsight_api.engine.response_models import LLMCallResult, TokenUsage
from hindsight_api.engine.retain.attachment_content import LoadedAttachment, attachment_placeholder
from hindsight_api.engine.retain.fact_extraction import _extract_facts_from_chunk

from hindsight_lakebase.databricks import DatabricksOAuthTokenProvider
from hindsight_lakebase.images import image_capabilities, image_fact_metadata, require_images
from hindsight_lakebase.ingestion import ingestion_policy, stamp_ingestion
from hindsight_lakebase.server import LOG_FIELDS

DATA = b"synthetic-image"
HASH = hashlib.sha256(DATA).hexdigest()
TOKEN = attachment_placeholder(HASH)


def image_config():
    return replace(
        HindsightConfig.from_env(),
        vlm_provider="databricks",
        vlm_model="system.ai.gpt-6-luna",
        llm_vision=True,
        llm_temperature_retain=None,
        retain_max_attachments_per_chunk=1,
        retain_extraction_mode="concise",
        retain_batch_enabled=False,
    )


def test_images_require_explicit_capability_and_inference():
    config = image_config()
    assert image_capabilities(config)["enabled"]
    for changes in (
        {"llm_vision": None},
        {"llm_temperature_retain": 0.1},
        {"vlm_provider": None},
        {"retain_extraction_mode": "chunks"},
        {"retain_batch_enabled": True},
    ):
        unsafe = replace(config, **changes)
        assert not image_capabilities(unsafe)["enabled"]
        with pytest.raises(RuntimeError, match="^memory_images_unconfigured$"):
            stamp_ingestion([{"metadata": {"dahlia_images": "1"}}], unsafe, None)
        assert ingestion_policy(config) != ingestion_policy(unsafe)
    assert ingestion_policy(config) != ingestion_policy(replace(config, vlm_model="system.ai.other"))
    assert ingestion_policy(config) == ingestion_policy(replace(config, vlm_api_key="SECRET"))


def test_missing_or_corrupt_image_is_not_text_evidence():
    with pytest.raises(RuntimeError, match="^memory_image_unavailable$"):
        require_images(TOKEN, {})
    with pytest.raises(RuntimeError, match="^memory_image_unavailable$"):
        require_images(TOKEN, {HASH[:12]: LoadedAttachment(media_type="image/webp", data=b"changed")})
    require_images(TOKEN, {HASH[:12]: LoadedAttachment(media_type="image/webp", data=DATA)})
    assert image_fact_metadata({"dahlia_images": "1"}, TOKEN)["dahlia_image_context"] == [HASH[:12]]
    assert image_fact_metadata({"dahlia_images": "1"}, "prose")["dahlia_image_context"] == []


async def test_only_image_chunks_use_bounded_vision_calls_and_missing_bytes_fail(caplog):
    caplog.set_level(logging.DEBUG, logger="hindsight_api")
    answer = LLMCallResult(content={"facts": []}, usage=TokenUsage())
    text = SimpleNamespace(call=AsyncMock(return_value=answer))
    vision = SimpleNamespace(call=AsyncMock(return_value=answer))
    loader = SimpleNamespace(
        load=AsyncMock(return_value={HASH[:12]: LoadedAttachment(media_type="image/webp", data=DATA)})
    )
    args = dict(
        chunk_index=0,
        total_chunks=1,
        event_date=datetime(2026, 1, 1),
        context="",
        llm_config=text,
        config=image_config(),
        attachment_loader=loader,
        vlm_config=vision,
        metadata={"dahlia_images": "1"},
    )
    await _extract_facts_from_chunk(chunk="plain text", **args)
    text.call.assert_awaited_once()
    vision.call.assert_not_awaited()
    await _extract_facts_from_chunk(chunk=TOKEN, **args)
    vision.call.assert_awaited_once()
    call = vision.call.call_args.kwargs
    assert call["max_completion_tokens"] == 4096 and call["max_retries"] == 0
    assert any(part["type"] == "image_url" for part in call["messages"][1]["content"])
    loader.load.return_value = {}
    with pytest.raises(RuntimeError, match="memory_image_unavailable"):
        await _extract_facts_from_chunk(chunk=TOKEN, **args)
    assert vision.call.await_count == 1
    loader.load.return_value = {HASH[:12]: LoadedAttachment(media_type="image/webp", data=DATA)}
    vision.call.side_effect = RuntimeError("SECRET-IMAGE-FAILURE data:image/webp;base64,c3ludGhldGlj")
    with pytest.raises(Exception):
        await _extract_facts_from_chunk(chunk=f"SECRET-IMAGE-QUESTION {TOKEN}", **args)
    assert vision.call.await_count == 2  # No nested retry after a failed vision call.
    formatter = JsonFormatter(allowed_fields=frozenset(LOG_FIELDS))
    assert caplog.records
    rendered = "\n".join(formatter.format(record) for record in caplog.records)
    assert "SECRET-IMAGE" not in rendered and "base64" not in rendered and HASH not in rendered


@pytest.mark.parametrize("model", ["system.ai.gpt-6-luna", "gpt-5"])
async def test_databricks_preserves_multimodal_parts_and_uses_oauth(monkeypatch, model):
    monkeypatch.setenv("DATABRICKS_HOST", "https://workspace.example")
    monkeypatch.setenv("DATABRICKS_CLIENT_ID", "synthetic")
    monkeypatch.setenv("DATABRICKS_CLIENT_SECRET", "synthetic")
    token = AsyncMock(return_value="synthetic-token")
    monkeypatch.setattr(DatabricksOAuthTokenProvider, "get_token_async", token)
    provider = OpenAICompatibleLLM(
        provider="databricks", model=model, api_key=None, base_url=None, extra_body={"max_tokens": 16000}
    )
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
                "choices": [
                    {"index": 0, "message": {"role": "assistant", "content": "synthetic"}, "finish_reason": "stop"}
                ],
            },
        )

    parts = [
        {"type": "text", "text": "untrusted data"},
        {"type": "image_url", "image_url": {"url": "data:image/webp;base64,c3ludGhldGlj"}},
    ]
    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
        monkeypatch.setattr(provider._client, "_client", client)
        await provider.call(
            messages=[{"role": "user", "content": parts}],
            max_retries=0,
            max_completion_tokens=4096,
            scope="dahlia_image_retain",
        )
    assert requests[0].headers["authorization"] == "Bearer synthetic-token"
    assert json.loads(requests[0].content)["messages"][0]["content"] == parts
    payload = json.loads(requests[0].content)
    assert payload.get("max_completion_tokens", payload.get("max_tokens")) == 4096
    assert payload.get("max_tokens", 4096) <= 4096
    token.assert_awaited()

import asyncio
import copy
import io
import json
import logging
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from hindsight_api import MemoryEngine, RequestContext
from hindsight_api.config import JsonFormatter, clear_config_cache, get_config

from hindsight_lakebase import server


@pytest.mark.parametrize("free_form,labels,expected", [(False, [], False), (True, [], True), (False, ["label"], True)])
async def test_entity_free_banks_block_entities_in_internal_recall(free_form, labels, expected):
    engine = object.__new__(MemoryEngine)
    engine._authenticate_tenant = AsyncMock()
    engine._require_bank_exists = AsyncMock()
    engine._resolve_fuzzy_tag_groups = AsyncMock(return_value=None)
    engine._operation_validator = None
    engine._config_resolver = SimpleNamespace(
        get_bank_config=AsyncMock(
            return_value={
                "entities_allow_free_form": free_form,
                "entity_labels": labels,
                "enable_graph_retrieval": False,
            }
        )
    )
    engine._search_semaphore = asyncio.Semaphore(1)
    engine._search_with_retries = AsyncMock(return_value=SimpleNamespace(results=[]))
    await engine.recall_async(bank_id="test", query="test", include_entities=True, request_context=RequestContext())
    args, kwargs = engine._search_with_retries.call_args
    assert args[7] is expected
    assert kwargs["enable_graph_retrieval"] is False


def test_app_logging_omits_content_and_exception_text(monkeypatch):
    import hindsight_api.main
    import uvicorn.config

    monkeypatch.setattr(uvicorn.config, "LOGGING_CONFIG", copy.deepcopy(uvicorn.config.LOGGING_CONFIG))
    for key in ("HINDSIGHT_API_LOG_FORMAT", "HINDSIGHT_API_LOG_JSON_FIELDS", "HINDSIGHT_API_ACCESS_LOG"):
        monkeypatch.setenv(key, "")
    monkeypatch.setattr(hindsight_api.main, "main", lambda: None)
    server.main()
    clear_config_cache()
    config = get_config()
    assert config.log_format == "json" and not config.access_log
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    formatters = [JsonFormatter(allowed_fields=frozenset(config.log_json_fields))]
    for name in ("default", "access"):
        spec = uvicorn.config.LOGGING_CONFIG["formatters"][name]
        assert spec["()"] == "hindsight_api.config.JsonFormatter"
        formatters.append(JsonFormatter(allowed_fields=frozenset(spec["allowed_fields"])))
    for formatter in formatters:
        handler.setFormatter(formatter)
        for level in (logging.INFO, logging.WARNING, logging.ERROR):
            error = ValueError("SECRET EXCEPTION")
            record = logging.LogRecord(
                "hindsight_api", level, __file__, 1, "SECRET QUERY %s", ("SECRET ANSWER",), (ValueError, error, None)
            )
            handler.handle(record)
    lines = stream.getvalue().splitlines()
    assert len(lines) == 9
    assert "SECRET" not in stream.getvalue()
    assert all(set(json.loads(line)) == {"severity", "timestamp", "logger"} for line in lines)

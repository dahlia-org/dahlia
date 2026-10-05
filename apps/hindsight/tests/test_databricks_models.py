import inspect
import os
import subprocess
import sys
from pathlib import Path

import yaml
from hindsight_api.config import clear_config_cache
from hindsight_api.engine.embeddings import create_embeddings_from_env
from hindsight_api.engine.llm_wrapper import create_llm_provider, requires_api_key
from hindsight_api.engine.providers.openai_responses_llm import OpenAIResponsesLLM


async def test_databricks_providers_use_app_oauth_without_api_keys(monkeypatch):
    monkeypatch.setenv("DATABRICKS_HOST", "https://workspace.cloud.databricks.com")
    monkeypatch.setenv("DATABRICKS_CLIENT_ID", "client")
    monkeypatch.setenv("DATABRICKS_CLIENT_SECRET", "secret")
    monkeypatch.setenv("HINDSIGHT_API_EMBEDDINGS_PROVIDER", "databricks")
    monkeypatch.setenv("HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL", "catalog.ai.qwen3-embedding-0-6b")
    monkeypatch.setenv("HINDSIGHT_API_EMBEDDINGS_OPENAI_DIMENSIONS", "1024")
    clear_config_cache()

    assert not requires_api_key("databricks")
    llm = create_llm_provider("databricks", None, "", "catalog.ai.gpt-5-6-luna", None)
    embeddings = create_embeddings_from_env()

    assert llm.provider == "databricks"
    assert llm.base_url == "https://workspace.cloud.databricks.com/ai-gateway/mlflow/v1"
    assert inspect.iscoroutinefunction(llm._client._api_key_provider)
    assert embeddings.provider_name == "databricks"
    assert embeddings.base_url == llm.base_url
    await embeddings.initialize()
    client = embeddings._loop_client()
    # AsyncOpenAI awaits the provider before each request, so the key is never replaced by a callable.
    assert inspect.iscoroutinefunction(client._api_key_provider)
    assert embeddings._loop_client() is client and client._api_key_provider == embeddings.api_key


def test_databricks_responses_provider_uses_app_oauth_without_api_keys(monkeypatch):
    monkeypatch.setenv("DATABRICKS_HOST", "https://workspace.cloud.databricks.com")
    monkeypatch.setenv("DATABRICKS_CLIENT_ID", "client")
    monkeypatch.setenv("DATABRICKS_CLIENT_SECRET", "secret")
    clear_config_cache()

    assert not requires_api_key("databricks-responses")
    llm = create_llm_provider("databricks-responses", None, "", "system.ai.gpt-6-luna", None)

    assert isinstance(llm, OpenAIResponsesLLM)
    assert llm.provider == "databricks-responses"
    assert llm.base_url == "https://workspace.cloud.databricks.com/ai-gateway/mlflow/v1"
    assert inspect.iscoroutinefunction(llm._client._api_key_provider)


def test_bundled_app_environment_starts_the_pinned_server():
    root = Path(__file__).resolve().parents[3]
    app = yaml.safe_load((root / "deploy/databricks/resources/hindsight.app.yml").read_text())
    variables = yaml.safe_load((root / "deploy/databricks/databricks.yml").read_text())["variables"]
    bundle = {f"${{var.{name}}}": str(spec["default"]) for name, spec in variables.items() if "default" in spec}
    env = {name: value for name, value in os.environ.items() if not name.startswith("HINDSIGHT_API_")}
    for item in app["resources"]["apps"]["hindsight"]["config"]["env"]:
        if "value" in item:
            env[item["name"]] = bundle.get(item["value"], item["value"])
    assert env["HINDSIGHT_API_RERANKER_PROVIDER"] == "local"
    # Injected by Databricks Apps; start_databricks.py derives the database URL at startup.
    env |= {
        "DATABRICKS_HOST": "https://workspace.cloud.databricks.com",
        "DATABRICKS_CLIENT_ID": "client",
        "DATABRICKS_CLIENT_SECRET": "secret",
        "HINDSIGHT_API_DATABASE_URL": "postgresql://app@localhost/db",
    }
    check = (
        "from hindsight_api.server import _memory as m\n"
        "for op in ('reflect', 'mental_model_refresh'):\n"
        "    assert type(getattr(m, f'_{op}_llm_config')._provider_impl).__name__ == 'OpenAIResponsesLLM', op\n"
        "assert type(m._retain_llm_config._provider_impl).__name__ == 'OpenAICompatibleLLM'\n"
    )
    result = subprocess.run([sys.executable, "-c", check], env=env, capture_output=True, text=True, timeout=180)
    assert result.returncode == 0, result.stderr[-2000:]

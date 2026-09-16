from hindsight_api.config import clear_config_cache
from hindsight_api.engine.embeddings import create_embeddings_from_env
from hindsight_api.engine.llm_wrapper import create_llm_provider, requires_api_key


def test_databricks_providers_use_app_oauth_without_api_keys(monkeypatch):
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
    assert callable(llm._client._api_key_provider)
    assert embeddings.provider_name == "databricks"
    assert embeddings.base_url == llm.base_url
    assert callable(embeddings.api_key)

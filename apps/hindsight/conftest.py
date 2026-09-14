import pytest


@pytest.fixture(autouse=True)
def clean_config(monkeypatch):
    from hindsight_api.config import clear_config_cache

    monkeypatch.setenv("HINDSIGHT_API_EMBEDDINGS_PROVIDER", "openai")
    monkeypatch.setenv("HINDSIGHT_API_RERANKER_PROVIDER", "none")
    monkeypatch.setenv("HINDSIGHT_API_TEXT_SEARCH_EXTENSION", "native")
    monkeypatch.setenv("HINDSIGHT_API_VECTOR_EXTENSION", "pgvector")
    monkeypatch.delenv("HINDSIGHT_API_LAKEBASE_TEXT_TOKENIZER", raising=False)
    clear_config_cache()
    yield
    clear_config_cache()


@pytest.fixture
def lakebase(monkeypatch):
    monkeypatch.setenv("HINDSIGHT_API_TEXT_SEARCH_EXTENSION", "lakebase_text")
    monkeypatch.setenv("HINDSIGHT_API_VECTOR_EXTENSION", "lakebase_vector")

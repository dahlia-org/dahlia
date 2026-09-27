#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
uv run --locked ruff check --config pyproject.toml src tests conftest.py scripts
uv run --locked ruff format --check --config pyproject.toml src tests conftest.py scripts
uv run --locked pytest -q
# Upstream's collection hooks must not run on the extension's tests.
HINDSIGHT_API_EMBEDDINGS_PROVIDER=openai HINDSIGHT_API_RERANKER_PROVIDER=rrf \
uv run --locked pytest -c pyproject.toml -q --confcutdir=.upstream/hindsight-api-slim \
  --deselect=.upstream/hindsight-api-slim/tests/test_bm25_term_selection.py::test_selects_rare_term_from_real_pg_stats \
  .upstream/hindsight-api-slim/tests/test_bm25_min_score_pushdown.py \
  .upstream/hindsight-api-slim/tests/test_bm25_term_selection.py \
  .upstream/hindsight-api-slim/tests/test_enable_text_search_flag.py \
  .upstream/hindsight-api-slim/tests/test_knowledge_bm25_dispatch.py \
  .upstream/hindsight-api-slim/tests/test_pg_extensions.py \
  .upstream/hindsight-api-slim/tests/test_vector_index.py

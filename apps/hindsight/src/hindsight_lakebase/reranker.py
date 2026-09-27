"""Resolve the deployment's existing reranker to immutable Hugging Face weights."""

import os

MODEL = "cross-encoder/mmarco-mMiniLMv2-L12-H384-v1"
REVISION = "1427fd652930e4ba29e8149678df786c240d8825"


def prepare_reranker():
    if os.environ.get("HINDSIGHT_API_RERANKER_PROVIDER") != "local":
        return
    if os.environ.get("HINDSIGHT_API_RERANKER_LOCAL_MODEL") != MODEL:
        return
    from huggingface_hub import snapshot_download
    from huggingface_hub.utils import disable_progress_bars

    disable_progress_bars()
    path = snapshot_download(
        repo_id=MODEL,
        revision=REVISION,
        allow_patterns=["*.json", "model.safetensors", "sentencepiece.bpe.model"],
    )
    # The upstream CrossEncoder accepts a local directory; no upstream model loader fork.
    os.environ["HINDSIGHT_API_RERANKER_LOCAL_MODEL"] = path

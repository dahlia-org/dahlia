"""Bounded inline image extraction; no canonical content or credentials in errors."""

import asyncio
import hashlib

from hindsight_api.config_resolver import apply_strategy
from hindsight_api.engine.llm_interface import OutputTooLongError
from hindsight_api.engine.retain.attachment_content import iter_placeholder_ids

# Reasoning tokens count against this budget; image chunks also carry transcript text.
MAX_COMPLETION_TOKENS = 16000
# Matches Hindsight's default LLM client timeout, which also bounds this call.
TIMEOUT_SECONDS = 120


def image_capabilities(config, *, applied=False):
    if config.retain_default_strategy and not applied:
        config = apply_strategy(config, config.retain_default_strategy)
    return {
        "enabled": bool(
            config.vlm_provider == "databricks"
            and config.vlm_model
            and config.llm_vision is True
            and config.llm_temperature_retain is None
            and config.retain_extraction_mode in ("concise", "verbose")
            and not config.retain_batch_enabled
            and config.retain_max_attachments_per_chunk == 1
        ),
        "provider": config.vlm_provider,
        "model": config.vlm_model,
        "max_count": config.retain_attachment_max_count,
        "max_bytes": config.retain_attachment_max_size_bytes,
        "max_per_chunk": config.retain_max_attachments_per_chunk,
        "max_completion_tokens": MAX_COMPLETION_TOKENS,
        "timeout": TIMEOUT_SECONDS,
        "retries": 0,
    }


def validate_image_settings(contents, config):
    if any((item.get("metadata") or {}).get("dahlia_images") == "1" for item in contents):
        if not image_capabilities(config, applied=True)["enabled"]:
            raise RuntimeError("memory_images_unconfigured")


def require_images(text, loaded):
    for attachment_id in iter_placeholder_ids(text):
        image = loaded.get(attachment_id)
        if image is None or hashlib.sha256(image.data).hexdigest()[:12] != attachment_id:
            raise RuntimeError("memory_image_unavailable")


def image_fact_metadata(metadata, chunk_text):
    if (metadata or {}).get("dahlia_images") != "1":
        return metadata
    return {**metadata, "dahlia_image_context": list(dict.fromkeys(iter_placeholder_ids(chunk_text)))}


class ImageOutputTooLongError(OutputTooLongError):
    """An image chunk exceeded the fixed budget; the worker does not retry it."""


async def image_call(llm, kwargs):
    # Keep retain admission control while bounding transport retries and output budget.
    async with asyncio.timeout(TIMEOUT_SECONDS):
        try:
            return await llm.call(
                **{
                    **kwargs,
                    "max_completion_tokens": MAX_COMPLETION_TOKENS,
                    "max_retries": 0,
                    "scope": "retain_dahlia_image",
                }
            )
        except OutputTooLongError as error:
            raise ImageOutputTooLongError(str(error)) from error


def bound_image_request(params, token_parameter):
    for key in ("max_tokens", "max_completion_tokens"):
        params.pop(key, None)
        if params.get("extra_body"):
            params["extra_body"].pop(key, None)
    params[token_parameter] = MAX_COMPLETION_TOKENS

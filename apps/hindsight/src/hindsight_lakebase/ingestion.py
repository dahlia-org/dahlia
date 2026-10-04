"""Projection recipe identity and the Databricks service-policy boundary.

This is not a PII scanner or a general prompt-injection defense. No credentials,
provider response bodies, or free-form policy reasons enter these identities/errors.
"""

import hashlib
import json

from hindsight_api.config import HindsightConfig
from hindsight_api.config_resolver import apply_strategy
from hindsight_api.engine.llm_interface import ProviderContentPolicyError

# Explicit allowlist: never serialize a resolved HindsightConfig (it contains keys).
_FIELDS = (
    "vlm_provider",
    "vlm_model",
    "llm_vision",
    "llm_temperature_retain",
    "llm_strict_schema_retain",
    "retain_batch_enabled",
    "retain_attachment_max_count",
    "retain_attachment_max_size_mb",
    "retain_extraction_mode",
    "retain_chunk_size",
    "retain_structured_chunk_size",
    "retain_chunk_batch_size",
    "retain_max_attachments_per_chunk",
    "retain_max_completion_tokens",
    "retain_extract_causal_links",
    "retain_optional_fact_dimensions",
    "retain_mission",
    "retain_custom_instructions",
    "entities_allow_free_form",
    "entity_labels",
    "store_document_text",
    "enable_observations",
    "observations_mission",
    "observation_scope_limits",
    "max_observations_per_scope",
    "reflect_mission",
    "llm_output_language",
    "consolidation_max_tokens",
    "consolidation_max_completion_tokens",
    "consolidation_dedup_threshold",
    "consolidation_source_facts_max_tokens",
    "consolidation_source_facts_max_tokens_per_observation",
    "memory_defense",
    "disposition_skepticism",
    "disposition_literalism",
    "disposition_empathy",
)
_OPERATIONS = ("", "retain_", "reflect_", "consolidation_", "mental_model_refresh_")


def ingestion_policy(config, *, strategy=None, applied=False):
    """Hash effective standard settings, including the selected strategy, not secrets."""
    selected = strategy or config.retain_default_strategy
    overrides = (config.retain_strategies or {}).get(selected) if selected else None
    if selected and not isinstance(overrides, dict):
        raise ValueError("memory_ingestion_strategy_invalid")
    effective = config if applied or not selected else apply_strategy(config, selected)
    recipe = {name: getattr(effective, name, None) for name in _FIELDS}
    recipe["strategy_overrides"] = {
        name: value
        for name, value in (overrides or {}).items()
        if name in HindsightConfig.get_configurable_fields() and name != "retain_strategies"
    }
    for operation in _OPERATIONS:
        for suffix in ("provider", "model", "reasoning_effort"):
            name = f"{operation}llm_{suffix}"
            recipe[name] = getattr(effective, name, None)
        recipe[f"{operation}llm_members"] = [
            {name: getattr(member, name, None) for name in ("provider", "model", "reasoning_effort")}
            for member in getattr(effective, f"{operation}llm_members", [])
        ]
    recipe.update(version=2, image_policy=3, upstream="f8950b0c07d9e34c76493dba802bb309f0ce60fd", strategy=selected)
    return hashlib.sha256(json.dumps(recipe, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def reject_service_policy(response, provider):
    """The documented HTTP-200 block envelope is not a generated assistant answer."""
    if provider != "databricks":
        return
    data = response if isinstance(response, dict) else response.model_dump()
    if data.get("databricks_service_policy") is not None:
        raise ProviderContentPolicyError("memory_policy_blocked")


def operation_error_code(result):
    """Expose only a fixed discriminator, including the upstream parent failure summary."""
    message = result.get("error_message") or ""
    if "ProviderContentPolicyError: memory_policy_blocked" in message:
        return "memory_policy_blocked"
    if "ImageOutputTooLongError:" in message:
        return "memory_output_too_long"
    return None


class IngestionConfigChangedError(RuntimeError):
    """The durable operation must be replaced under the new recipe, never relabelled."""


def stamp_ingestion(contents, config, strategy):
    from hindsight_lakebase.images import validate_image_settings

    validate_image_settings(contents, config)
    policy = ingestion_policy(config, strategy=strategy, applied=True)
    for item in contents:
        expected = (item.get("metadata") or {}).get("dahlia_expected_ingestion_policy")
        if expected is not None and (expected != policy or config.entities_allow_free_form or config.entity_labels):
            raise IngestionConfigChangedError("memory_ingestion_config_changed")
    return [
        {**item, "metadata": {**(item.get("metadata") or {}), "dahlia_ingestion_policy": policy}} for item in contents
    ]

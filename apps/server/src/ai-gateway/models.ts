import codexFallback from "./codex-0.149.1-fallback.json";
import codexCatalog from "./codex-0.149.1-models.json";

import type { GatewayModelList } from "./backend";

export interface CodexModelWire {
  [key: string]: unknown;
  slug: string;
  display_name: string;
  description: string | null;
  default_reasoning_level?: string | null;
  supported_reasoning_levels: Array<{ effort: string; description: string }>;
  shell_type: string;
  visibility: string;
  supported_in_api: boolean;
  priority: number;
  model_messages?: { instructions_template?: string | null; [key: string]: unknown };
}

const bundledCodexModels = (codexCatalog as { models: CodexModelWire[] }).models;
const ossReasoningLevels = [
  { effort: "none", description: "Fast responses without reasoning" },
  { effort: "low", description: "Fast responses with lighter reasoning" },
  { effort: "high", description: "Greater reasoning depth for complex problems" },
  { effort: "max", description: "Maximum reasoning depth for the hardest problems" },
];

export interface ModelInfo {
  id: string;
  displayName?: string | null;
}

export function modelList(entries: ModelInfo[]): GatewayModelList {
  return {
    object: "list",
    data: entries.map((entry) => ({
      id: entry.id, object: "model", created: 0, owned_by: "dahlia",
      display_name: entry.displayName || entry.id,
    })),
    models: codexModels(entries),
  };
}

function codexModels(entries: ModelInfo[]): CodexModelWire[] {
  const models = new Map(bundledCodexModels.map((model) => [
    model.slug,
    hiddenCodexModel(model.slug),
  ]));
  entries.forEach((entry, priority) => {
    const model = knownCodexModel(entry.id)
      ?? ossCodexModel(entry.id);
    models.set(entry.id, {
      ...model,
      slug: entry.id,
      display_name: entry.displayName || entry.id,
      visibility: "list",
      supported_in_api: true,
      priority,
    });
  });
  return [...models.values()];
}

function hiddenCodexModel(slug: string): CodexModelWire {
  const model = fallbackCodexModel(slug);
  return {
    ...model,
    visibility: "hide",
    model_messages: { ...model.model_messages, instructions_template: "" },
  };
}

function knownCodexModel(value: string): CodexModelWire | undefined {
  const normalized = value.trim().toLowerCase().replace(/^system\.ai\./, "");
  const model = bundledCodexModels.find((model) =>
    normalized === model.slug || normalized === model.slug.replaceAll(".", "-")
  );
  if (!model) return undefined;
  // Keep picker/runtime metadata without opting custom providers into OpenAI-internal transports.
  return {
    ...fallbackCodexModel(model.slug),
    description: model.description,
    default_reasoning_level: model.default_reasoning_level,
    supported_reasoning_levels: model.supported_reasoning_levels,
    shell_type: model.shell_type,
    model_messages: model.model_messages,
    include_skills_usage_instructions: model.include_skills_usage_instructions,
    include_plugin_usage_instructions: model.include_plugin_usage_instructions,
    include_apps_usage_instructions: model.include_apps_usage_instructions,
    default_reasoning_summary: model.default_reasoning_summary,
    support_verbosity: model.support_verbosity,
    default_verbosity: model.default_verbosity,
    apply_patch_tool_type: model.apply_patch_tool_type,
    truncation_policy: model.truncation_policy,
    supports_image_detail_original: model.supports_image_detail_original,
    context_window: model.context_window,
    max_context_window: model.max_context_window,
    auto_compact_token_limit: model.auto_compact_token_limit,
    comp_hash: model.comp_hash,
    effective_context_window_percent: model.effective_context_window_percent,
    input_modalities: model.input_modalities,
    model_specialty: model.model_specialty,
    multi_agent_version: model.multi_agent_version,
  };
}

function ossCodexModel(slug: string): CodexModelWire {
  return {
    ...fallbackCodexModel(slug),
    default_reasoning_level: "max",
    supported_reasoning_levels: ossReasoningLevels,
  };
}

function fallbackCodexModel(slug: string): CodexModelWire {
  return {
    slug,
    display_name: slug,
    description: null,
    default_reasoning_level: null,
    supported_reasoning_levels: [],
    shell_type: "default",
    visibility: "list",
    supported_in_api: true,
    priority: 99,
    availability_nux: null,
    upgrade: null,
    model_messages: {
      instructions_template: codexFallback.base_instructions,
      instructions_variables: null,
      approvals: null,
      collaboration_modes: null,
      auto_review: null,
      permissions: null,
      multi_agent: null,
    },
    include_apps_usage_instructions: false,
    support_verbosity: false,
    default_verbosity: null,
    apply_patch_tool_type: null,
    truncation_policy: { mode: "bytes", limit: 10_000 },
    context_window: 272_000,
    max_context_window: 272_000,
    experimental_supported_tools: [],
  };
}

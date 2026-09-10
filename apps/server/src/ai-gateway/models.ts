import catalog from "./databricks-models.json";
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

// Suppress Codex 0.153.4 built-ins when its custom-provider catalog merges remote models.
const databricksDefinitions: readonly CodexModelWire[] = [
  ...catalog.models,
  ...[
    "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-daybreak-blue-latest",
    "gpt-daybreak-red-latest", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.2",
  ].map((slug) => ({ ...catalog.models[0]!, slug, display_name: slug, visibility: "hide", supported_in_api: false })),
];

export interface ModelInfo {
  id: string;
  displayName?: string | null;
}

export function modelList(entries: ModelInfo[], definitions: readonly CodexModelWire[] = databricksDefinitions): GatewayModelList {
  const models = new Map(definitions.map((model) => [model.slug, model]));
  const available = new Set(entries.map((entry) => entry.id));
  return {
    object: "list",
    data: entries.map((entry) => ({
      id: entry.id, object: "model", created: 0, owned_by: "dahlia",
      display_name: entry.displayName?.trim() || models.get(entry.id)?.display_name || entry.id,
    })),
    models: definitions.filter((model) => available.has(model.slug) || (model.visibility === "hide" && !model.supported_in_api)).map((model) => ({ ...model })),
  };
}

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

export interface ModelInfo {
  id: string;
  displayName?: string | null;
}

export function modelList(entries: ModelInfo[], definitions: readonly CodexModelWire[] = catalog.models): GatewayModelList {
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

import { z } from "zod";
// codex-models.json is generated next to apps/server/resources/codex by `pnpm codex-models:generate`; Server ships its provenance and license.
import bundled from "./codex-models.json";
import type { CodexModelWire, GatewayModelList } from "./gateway-models";

export const reasoningEffortSchema = z.enum(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]);
export type ReasoningEffort = z.infer<typeof reasoningEffortSchema>;
export interface AiModel {
  id: string;
  displayName: string;
  defaultReasoningEffort: ReasoningEffort;
  supportedReasoningEfforts: Array<{ effort: ReasoningEffort; description: string }>;
}

type PickerModel = Pick<CodexModelWire, "slug" | "display_name" | "supported_in_api" | "visibility"
  | "default_reasoning_level" | "supported_reasoning_levels"> & { input_modalities?: unknown };

/** Shared picker projection; never changes the Gateway catalog. */
export function pickerModels(catalog: Pick<GatewayModelList, "models" | "data">, includeBundled = false): PickerModel[] {
  const remote = new Set(catalog.models.map(({ slug }) => slug));
  const published = new Map(catalog.data.map((model) => [model.id, model]));
  const merged = new Map<string, PickerModel>(
    (includeBundled ? bundled.models : []).map((model) => [model.slug, model]));
  // Replace whole definitions, including hidden entries, so upstream can suppress a built-in.
  for (const model of catalog.models) merged.set(model.slug, model);
  const ordered = new Set([...(includeBundled ? bundled.models.map(({ slug }) => slug) : []), ...published.keys()]);
  return [...ordered].flatMap((slug) => {
    const definition = merged.get(slug);
    if (!definition || !definition.supported_in_api || definition.visibility === "hide"
      || (remote.has(definition.slug) && !published.has(definition.slug))) return [];
    return [{ ...definition, display_name: published.get(definition.slug)?.display_name ?? definition.display_name }];
  });
}

/** Chat request validation uses the same picker projection. */
export function chatModels(catalog: Pick<GatewayModelList, "models" | "data">, includeBundled = false): AiModel[] {
  return pickerModels(catalog, includeBundled).flatMap((definition) => {
    const defaultEffort = reasoningEffortSchema.safeParse(definition.default_reasoning_level);
    const supported = definition.supported_reasoning_levels.flatMap(({ effort, description }) => {
      const parsed = reasoningEffortSchema.safeParse(effort);
      return parsed.success ? [{ effort: parsed.data, description }] : [];
    });
    if (!defaultEffort.success || !supported.some(({ effort }) => effort === defaultEffort.data)) return [];
    return [{ id: definition.slug, displayName: definition.display_name,
      defaultReasoningEffort: defaultEffort.data, supportedReasoningEfforts: supported }];
  });
}

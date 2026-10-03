import { z } from "zod";
import bundled from "../../resources/codex/models.json";
import type { GatewayModelList } from "../ai-gateway/backend";
import type { CodexModelWire } from "../ai-gateway/models";

export const reasoningEffortSchema = z.enum(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]);
export type ReasoningEffort = z.infer<typeof reasoningEffortSchema>;
export interface AiModel {
  id: string;
  displayName: string;
  defaultReasoningEffort: ReasoningEffort;
  supportedReasoningEfforts: Array<{ effort: ReasoningEffort; description: string }>;
}

/** Shared picker projection and request validation; never changes the Gateway catalog. */
export function chatModels(catalog: Pick<GatewayModelList, "models" | "data">, includeBundled = false): AiModel[] {
  const remote = new Set(catalog.models.map(({ slug }) => slug));
  const published = new Map(catalog.data.map((model) => [model.id, model]));
  const merged = new Map<string, Pick<CodexModelWire, "slug" | "display_name" | "supported_in_api" | "visibility"
    | "default_reasoning_level" | "supported_reasoning_levels">>(
    (includeBundled ? bundled.models : []).map((model) => [model.slug, model]));
  // Replace whole definitions, including hidden entries, so upstream can suppress a built-in.
  for (const model of catalog.models) merged.set(model.slug, model);
  const ordered = new Set([...(includeBundled ? bundled.models.map(({ slug }) => slug) : []), ...published.keys()]);
  return [...ordered].flatMap((slug) => {
    const definition = merged.get(slug);
    if (!definition || !definition.supported_in_api || definition.visibility === "hide"
      || (remote.has(definition.slug) && !published.has(definition.slug))) return [];
    const defaultEffort = reasoningEffortSchema.safeParse(definition.default_reasoning_level);
    const supported = definition.supported_reasoning_levels.flatMap(({ effort, description }) => {
      const parsed = reasoningEffortSchema.safeParse(effort);
      return parsed.success ? [{ effort: parsed.data, description }] : [];
    });
    if (!defaultEffort.success || !supported.some(({ effort }) => effort === defaultEffort.data)) return [];
    return [{ id: definition.slug, displayName: published.get(definition.slug)?.display_name ?? definition.display_name,
      defaultReasoningEffort: defaultEffort.data, supportedReasoningEfforts: supported }];
  });
}

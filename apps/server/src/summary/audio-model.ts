import type { GatewayModelList } from "../ai-gateway/backend";

export function isAudioSummaryModel(id: string, catalog: GatewayModelList): boolean {
  return id.startsWith("gemini-") && catalog.data.some((model) => model.id === id)
    && catalog.models.some((model) => model.slug === id
      && Array.isArray(model.input_modalities) && model.input_modalities.includes("audio"));
}

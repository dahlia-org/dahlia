import type { GatewayModelList } from "../ai-gateway/backend";

export function isAudioSummaryModel(id: string, catalog: GatewayModelList): boolean {
  return id.startsWith("gemini-") && catalog.data.some((model) => model.id === id)
    && catalog.models.some((model) => model.slug === id
      && Array.isArray(model.input_modalities) && model.input_modalities.includes("audio"));
}

export function isStructuredSummaryModel(id: string, catalog: GatewayModelList): boolean {
  return catalog.data.some((model) => model.id === id)
    && catalog.models.some((model) => model.slug === id && model.supported_in_api);
}

export function isSummaryModel(id: string, catalog: GatewayModelList, method: "transcript" | "audio"): boolean {
  const model = catalog.models.find((model) => model.slug === id);
  return isStructuredSummaryModel(id, catalog)
    && (!Array.isArray(model?.summary_methods) || model.summary_methods.includes(method))
    && (method !== "audio" || isAudioSummaryModel(id, catalog));
}

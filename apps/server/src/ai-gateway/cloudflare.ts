import type { ProviderConfig } from "../config";
import { sendOpenAIResponses, type GatewayFetch } from "./adapters";
import type { AIGatewayBackend, RequestBody, RequestContext } from "./backend";
import { modelList } from "./models";

export function cloudflareHeaders(provider: { gatewayId?: string }): Record<string, string> {
  return { "cf-aig-gateway-id": provider.gatewayId ?? "default", "cf-aig-collect-log": "false",
    "cf-aig-collect-log-payload": "false", "cf-aig-skip-cache": "true", "cf-aig-max-attempts": "1" };
}

export function cloudflareModel(model: string): string {
  if (model === "gpt-4.1" || model === "gpt-5.6-luna") return `openai/${model}`;
  if (model === "gemini-3-flash") return `google/${model}`;
  return model;
}

export function cloudflareModels() {
  const catalog = modelList([{ id: "gpt-5.6-luna" }, { id: "gpt-4.1" }, { id: "gemini-3-flash" }]);
  for (const [slug, displayName, efforts, audio] of [
    ["gpt-4.1", "GPT-4.1", ["none"], false],
    ["gemini-3-flash", "Gemini 3 Flash", ["minimal", "low", "medium", "high"], true],
  ] as const) {
    catalog.models = catalog.models.filter((entry) => entry.slug !== slug);
    catalog.models.push({ slug, display_name: displayName, description: null, shell_type: "default",
      visibility: "list", supported_in_api: true, priority: catalog.models.length,
      default_reasoning_level: audio ? "medium" : "none",
      supported_reasoning_levels: efforts.map((effort) => ({ effort, description: effort })),
      input_modalities: ["text", "image", ...(audio ? ["audio"] : [])], supports_json_schema: true });
  }
  for (const model of catalog.models) {
    model.summary_methods = model.slug === "gpt-4.1" ? ["transcript"] : model.slug === "gemini-3-flash" ? ["audio"] : [];
  }
  return catalog;
}

export class CloudflareBackend implements AIGatewayBackend {
  constructor(
    private readonly provider: Extract<ProviderConfig, { apiKey: string }>,
    private readonly transport: GatewayFetch = fetch,
  ) {}

  listModels() {
    return Promise.resolve(cloudflareModels());
  }

  responses(body: RequestBody, context: RequestContext): Promise<Response> {
    return sendOpenAIResponses(this.provider, `Bearer ${this.provider.apiKey}`, {
      body: JSON.stringify({ ...body, model: context.upstreamModel ?? cloudflareModel(body.model) }),
      requestHeaders: context.headers,
      signal: context.signal,
      upstreamHeaders: cloudflareHeaders(this.provider),
    }, this.transport);
  }
}

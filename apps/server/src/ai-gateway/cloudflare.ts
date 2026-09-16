import type { ProviderConfig } from "../config";
import { sendOpenAIResponses, type GatewayFetch } from "./adapters";
import type { AIGatewayBackend, ListModelsRequest, RequestBody, RequestContext } from "./backend";
import { modelList } from "./models";
import catalog from "./cloudflare-models.json";

export function cloudflareHeaders(provider: { gatewayId?: string }): Record<string, string> {
  return { "cf-aig-gateway-id": provider.gatewayId ?? "default", "cf-aig-collect-log": "false",
    "cf-aig-collect-log-payload": "false", "cf-aig-skip-cache": "true", "cf-aig-max-attempts": "1" };
}

export function cloudflareModel(model: string): string {
  if (model === "gpt-4.1" || model === "gpt-5.6-luna") return `openai/${model}`;
  if (model === "gemini-3-flash") return `google/${model}`;
  return model;
}

export function cloudflareModels(models: readonly string[] = catalog.models.map((model) => model.slug)) {
  return modelList(models.map((id) => ({ id })), catalog.models);
}

export class CloudflareBackend implements AIGatewayBackend {
  constructor(
    private readonly provider: Extract<ProviderConfig, { apiKey: string }>,
    private readonly transport: GatewayFetch = fetch,
    private readonly models: readonly string[] = [],
  ) {}

  listModels(request: ListModelsRequest) {
    void request;
    return Promise.resolve(cloudflareModels(this.models));
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

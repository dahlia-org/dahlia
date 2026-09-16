import type { ProviderConfig } from "../config";
import { sendOpenAIResponses, type GatewayFetch } from "./adapters";
import type { AIGatewayBackend, ListModelsRequest, RequestBody, RequestContext } from "./backend";
import { modelList } from "./models";
import catalog from "./openai-models.json";

export class OpenAIBackend implements AIGatewayBackend {
  constructor(
    private readonly provider: Extract<ProviderConfig, { apiKey: string }>,
    private readonly transport: GatewayFetch = fetch,
    private readonly models: readonly string[] = [],
  ) {}

  listModels(request: ListModelsRequest) {
    void request;
    return Promise.resolve(modelList(this.models.map((id) => ({ id })), catalog.models));
  }

  responses(body: RequestBody, context: RequestContext): Promise<Response> {
    return sendOpenAIResponses(this.provider, `Bearer ${this.provider.apiKey}`, {
      body: JSON.stringify({ ...body, model: context.upstreamModel ?? body.model }),
      requestHeaders: context.headers,
      signal: context.signal,
    }, this.transport);
  }
}

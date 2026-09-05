import type { ProviderConfig } from "../config";
import { sendOpenAIResponses, type GatewayFetch } from "./adapters";
import type { AIGatewayBackend, RequestBody, RequestContext } from "./backend";
import { modelList } from "./models";

export class OpenAIBackend implements AIGatewayBackend {
  constructor(
    private readonly provider: Extract<ProviderConfig, { apiKey: string }>,
    private readonly transport: GatewayFetch = fetch,
  ) {}

  listModels() {
    // Mock discovery until this backend has a model catalog implementation.
    return Promise.resolve(modelList([{ id: "gpt-5.6-luna" }]));
  }

  responses(body: RequestBody, context: RequestContext): Promise<Response> {
    return sendOpenAIResponses(this.provider, `Bearer ${this.provider.apiKey}`, {
      body: JSON.stringify({ ...body, model: context.upstreamModel ?? body.model }),
      requestHeaders: context.headers,
      signal: context.signal,
    }, this.transport);
  }
}

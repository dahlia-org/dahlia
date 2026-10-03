import type { ProviderConfig } from "../config";
import { DatabricksTokenProvider, tokenUntilAborted } from "../databricks/token";
import { sendOpenAIResponses, type GatewayFetch } from "./adapters";
import type { AIGatewayBackend, GatewayModelList, ListModelsRequest, RequestBody, RequestContext } from "./backend";
import { GatewayRequestError } from "./errors";
import { z } from "zod";

export class DatabricksBackend implements AIGatewayBackend {
  constructor(
    private readonly provider: Extract<ProviderConfig, { backend: "databricks" }>,
    _models: readonly string[],
    private readonly transport: GatewayFetch = fetch,
    private readonly tokens?: DatabricksTokenProvider,
  ) {}

  async responses(body: RequestBody, context: RequestContext): Promise<Response> {
    return sendOpenAIResponses(this.provider, `Bearer ${await databricksAccessToken(context.headers, this.tokens, context.signal)}`, {
      body: JSON.stringify({ ...body, model: context.upstreamModel ?? body.model }),
      requestHeaders: context.headers,
      signal: context.signal,
      upstreamHeaders: { "Databricks-Ai-Gateway-Request-Tags": JSON.stringify({ user_id: context.identity.userId }) },
    }, this.transport);
  }

  async listModels(request: ListModelsRequest): Promise<GatewayModelList> {
    const signal = AbortSignal.any([request.signal, AbortSignal.timeout(10_000)]);
    const endpoint = new URL(`${this.provider.baseUrl}/models`);
    if (request.clientVersion) endpoint.searchParams.set("client_version", request.clientVersion);
    const response = await this.transport(endpoint, {
      headers: {
        accept: "application/json",
        authorization: `Bearer ${await databricksAccessToken(request.headers ?? new Headers(), this.tokens, signal)}`,
      },
      signal,
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new GatewayRequestError("Databricks model discovery failed", response.status, "model_discovery_failed");
    }
    const parsed = catalogSchema.safeParse(await response.json().catch(() => null));
    if (!parsed.success) throw new GatewayRequestError("Invalid Databricks model catalog", 502, "invalid_model_catalog");
    const { models } = parsed.data;
    return {
      ...parsed.data,
      object: "list",
      data: models.filter((model) => model.supported_in_api).map((model) => ({
        id: model.slug, object: "model", created: 0, owned_by: "databricks", display_name: model.display_name,
      })),
      models,
    };
  }
}

export async function databricksAccessToken(headers: Headers, tokens?: DatabricksTokenProvider, signal?: AbortSignal): Promise<string> {
  const forwarded = headers.get("x-forwarded-access-token")?.trim();
  if (forwarded) return forwarded;
  if (tokens) return signal ? tokenUntilAborted(tokens, signal) : tokens.getToken();
  throw new GatewayRequestError(
    "Databricks access token is unavailable",
    401,
    "databricks_access_token_required",
  );
}

const catalogSchema = z.object({
  models: z.array(z.object({
    slug: z.string().min(1),
    display_name: z.string(),
    description: z.string().nullable(),
    default_reasoning_level: z.string().nullable().optional(),
    model_messages: z.object({ instructions_template: z.string().nullable().optional() }).passthrough().optional(),
    supported_reasoning_levels: z.array(z.object({ effort: z.string(), description: z.string() }).passthrough()),
    shell_type: z.string(),
    visibility: z.string(),
    supported_in_api: z.boolean(),
    priority: z.number(),
  }).passthrough()),
}).passthrough();

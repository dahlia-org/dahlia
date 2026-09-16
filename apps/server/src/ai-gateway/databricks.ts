import type { DatabricksWorkspaceConfig, ProviderConfig } from "../config";
import { sendOpenAIResponses, type GatewayFetch } from "./adapters";
import type { AIGatewayBackend, ListModelsRequest, RequestBody, RequestContext } from "./backend";
import { GatewayRequestError } from "./errors";
import { modelList } from "./models";

export class DatabricksBackend implements AIGatewayBackend {
  private readonly models: readonly string[];

  constructor(
    private readonly provider: Extract<ProviderConfig, { backend: "databricks" }>,
    modelsOrLegacyWorkspace: readonly string[] | DatabricksWorkspaceConfig,
    private readonly transport: GatewayFetch = fetch,
  ) {
    this.models = Array.isArray(modelsOrLegacyWorkspace) ? modelsOrLegacyWorkspace : [];
  }

  responses(body: RequestBody, context: RequestContext): Promise<Response> {
    return sendOpenAIResponses(this.provider, forwardedDatabricksAuthorization(context.headers), {
      body: JSON.stringify({ ...body, model: context.upstreamModel ?? body.model }),
      requestHeaders: context.headers,
      signal: context.signal,
      upstreamHeaders: { "Databricks-Ai-Gateway-Request-Tags": JSON.stringify({ user_id: context.identity.userId }) },
    }, this.transport);
  }

  listModels(request: ListModelsRequest) {
    void request;
    return Promise.resolve(modelList(this.models.map((id) => ({ id }))));
  }
}

function forwardedDatabricksAuthorization(headers: Headers): string {
  const token = headers.get("x-forwarded-access-token")?.trim();
  if (!token) {
    throw new GatewayRequestError(
      "Databricks access token is unavailable",
      401,
      "databricks_access_token_required",
    );
  }
  return `Bearer ${token}`;
}

import type { ProviderConfig, DatabricksWorkspaceConfig } from "../config";
import { DatabricksTokenProvider } from "../databricks/token";
import { listDatabricksModelServices, sendOpenAIResponses, type GatewayFetch } from "./adapters";
import type { AIGatewayBackend, GatewayModelList, ListModelsRequest, RequestBody, RequestContext } from "./backend";
import { GatewayRequestError } from "./errors";
import { modelList, type ModelInfo } from "./models";

const DATABRICKS_MODEL_TIMEOUT_MS = 30_000;
const SHORT_MODEL_PATTERN = /^[a-z0-9][a-z0-9_-]{0,254}$/;

export class DatabricksBackend implements AIGatewayBackend {
  private readonly tokens: DatabricksTokenProvider;

  constructor(
    private readonly provider: Extract<ProviderConfig, { backend: "databricks" }>,
    workspace: DatabricksWorkspaceConfig,
    private readonly transport: GatewayFetch = fetch,
  ) {
    this.tokens = new DatabricksTokenProvider(workspace, transport);
  }

  responses(body: RequestBody, context: RequestContext): Promise<Response> {
    if (!context.upstreamModel && !SHORT_MODEL_PATTERN.test(body.model)) {
      throw new GatewayRequestError("A short model name is required", 400, "invalid_model");
    }
    return sendOpenAIResponses(this.provider, forwardedDatabricksAuthorization(context.headers), {
      body: JSON.stringify({ ...body, model: context.upstreamModel ?? `${this.provider.modelSchema}.${body.model}` }),
      requestHeaders: context.headers,
      signal: context.signal,
      upstreamHeaders: { "Databricks-Ai-Gateway-Request-Tags": JSON.stringify({ user_id: context.identity.userId }) },
    }, this.transport);
  }

  async listModels(request: ListModelsRequest): Promise<GatewayModelList> {
    const provider = this.provider;
    const deadline = AbortSignal.timeout(DATABRICKS_MODEL_TIMEOUT_MS);
    let token: string;
    try {
      token = await this.tokens.getToken();
    } catch (error) {
      throw databricksModelListError("provider_models_unavailable", "authentication_error", {
        errorName: error instanceof Error ? error.name : "UnknownError",
      });
    }
    const authorization = `Bearer ${token}`;
    const signal = AbortSignal.any([request.signal, deadline]);
    const models: ModelInfo[] = [];
    const pageTokens = new Set<string>();
    let pageToken: string | undefined;
    do {
      const response = await listDatabricksModelServices(
        provider,
        authorization,
        signal,
        this.transport,
        pageToken,
      ).catch((error: unknown) => {
        throw databricksModelListError("provider_models_unavailable", "transport_error", {
          errorName: error instanceof Error ? error.name : "UnknownError",
        });
      });
      const requestId = databricksRequestId(response.headers);
      if (!response.ok) {
        throw databricksModelListError("provider_models_unavailable", "upstream_http_error", {
          status: response.status,
          requestId,
        });
      }
      const body: unknown = await response.json().catch(() => undefined);
      if (!body || typeof body !== "object" || Array.isArray(body)
        || ("model_services" in body && !Array.isArray(body.model_services))) {
        throw databricksModelListError("provider_models_invalid", "invalid_response_shape", { requestId });
      }
      const modelServices = ("model_services" in body ? body.model_services : []) as unknown[];
      for (const entry of modelServices) {
        if (!entry || typeof entry !== "object" || !("name" in entry) || typeof entry.name !== "string") {
          throw databricksModelListError("provider_models_invalid", "invalid_model_entry", { requestId });
        }
        const resourceName = entry.name.trim();
        const prefix = "model-services/";
        const id = resourceName.startsWith(prefix) ? resourceName.slice(prefix.length) : "";
        const shortId = id.slice(provider.modelSchema.length + 1);
        if (!id.startsWith(`${provider.modelSchema}.`) || !SHORT_MODEL_PATTERN.test(shortId)) {
          throw databricksModelListError("provider_models_invalid", "invalid_model_name", { requestId });
        }
        models.push({ id: shortId });
      }
      const nextPageToken: unknown = "next_page_token" in body ? body.next_page_token : undefined;
      if (nextPageToken !== undefined && typeof nextPageToken !== "string") {
        throw databricksModelListError("provider_models_invalid", "invalid_page_token", { requestId });
      }
      pageToken = nextPageToken?.trim() || undefined;
      if (pageToken && pageTokens.has(pageToken)) {
        throw databricksModelListError("provider_models_invalid", "repeated_page_token", { requestId });
      }
      if (pageToken) pageTokens.add(pageToken);
    } while (pageToken);
    return modelList(models);
  }
}

function databricksModelListError(
  code: "provider_models_unavailable" | "provider_models_invalid",
  reason: string,
  details: Record<string, unknown>,
): GatewayRequestError {
  console.error(JSON.stringify({ level: "error", event: "databricks_model_list_failed", reason, ...details }));
  const message = code === "provider_models_unavailable"
    ? "Databricks model list is unavailable"
    : "Databricks model list is invalid";
  return new GatewayRequestError(message, 502, code);
}

function databricksRequestId(headers: Headers): string | undefined {
  return headers.get("x-databricks-request-id")
    || headers.get("x-request-id")
    || headers.get("request-id")
    || undefined;
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

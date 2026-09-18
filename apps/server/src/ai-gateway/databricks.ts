import type { ProviderConfig } from "../config";
import { DatabricksTokenProvider } from "../databricks/token";
import { sendOpenAIResponses, type GatewayFetch } from "./adapters";
import type { AIGatewayBackend, ListModelsRequest, RequestBody, RequestContext } from "./backend";
import { GatewayRequestError } from "./errors";
import { modelList } from "./models";

export class DatabricksBackend implements AIGatewayBackend {
  constructor(
    private readonly provider: Extract<ProviderConfig, { backend: "databricks" }>,
    private readonly models: readonly string[],
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

  listModels(request: ListModelsRequest) {
    void request;
    return Promise.resolve(modelList(this.models.map((id) => ({ id }))));
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

function tokenUntilAborted(tokens: DatabricksTokenProvider, signal: AbortSignal): Promise<string> {
  signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const abort = () => reject(new DOMException("Request was cancelled", "AbortError"));
    signal.addEventListener("abort", abort, { once: true });
    const settle = <T>(callback: (value: T) => void, value: T) => {
      signal.removeEventListener("abort", abort);
      callback(value);
    };
    tokens.getToken().then((token) => settle(resolve, token), (error: unknown) => settle(reject, error));
  });
}

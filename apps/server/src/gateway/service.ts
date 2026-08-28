import type { AuthStore } from "../auth/store";
import type { AppConfig, ProviderConfig } from "../config";
import { sendOpenAIResponses, type GatewayFetch } from "./adapters";

interface CachedToken {
  expiresAt: number;
  value: string;
}

const DATABRICKS_TOKEN_TIMEOUT_MS = 30_000;

export class GatewayRequestError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code: string,
  ) {
    super(message);
  }
}

export class GatewayService {
  private databricksToken?: CachedToken;
  private databricksTokenRequest?: Promise<CachedToken>;

  constructor(
    private readonly config: AppConfig,
    private readonly store: Pick<AuthStore, "getEnabledModelAlias" | "listModelAliases">,
    private readonly transport: GatewayFetch = fetch,
  ) {}

  async models() {
    if (!this.config.provider) return { object: "list", data: [] };
    let aliases;
    try {
      aliases = await this.store.listModelAliases();
    } catch {
      throw new GatewayRequestError("Model registry is unavailable", 503, "model_registry_unavailable");
    }
    return {
      object: "list",
      data: aliases.filter((alias) => alias.enabled).map((alias) => ({
        id: alias.alias,
        object: "model",
        created: Math.floor(alias.createdAt.getTime() / 1000),
        owned_by: "dahlia",
        display_name: alias.displayName || alias.alias,
      })),
    };
  }

  async responses(request: Request): Promise<Response> {
    this.assertRequestCanBeRead(request);
    const body = await parseBoundedJsonObject(request, this.config.maxRequestBytes);
    const model = body.model;
    if (typeof model !== "string" || !model) {
      throw new GatewayRequestError("model is required", 400, "model_required");
    }
    let alias;
    try {
      alias = await this.store.getEnabledModelAlias(model);
    } catch {
      throw new GatewayRequestError("Model registry is unavailable", 503, "model_registry_unavailable");
    }
    if (!alias) {
      throw new GatewayRequestError(`Model '${model}' is not available`, 404, "model_not_found");
    }
    const provider = this.config.provider;
    if (!provider) {
      throw new GatewayRequestError("AI provider is not configured", 503, "provider_not_configured");
    }
    const upstreamBody = JSON.stringify({ ...body, model: alias.upstreamModel });
    const authorization = provider.backend === "databricks"
      ? `Bearer ${await this.getDatabricksToken(provider)}`
      : `Bearer ${provider.apiKey}`;
    const upstream = await sendOpenAIResponses(
      provider,
      authorization,
      {
        body: upstreamBody,
        requestHeaders: request.headers,
        signal: request.signal,
      },
      this.transport,
    );
    return proxyUpstreamResponse(upstream);
  }

  private async getDatabricksToken(provider: Extract<ProviderConfig, { backend: "databricks" }>): Promise<string> {
    if (this.databricksToken && this.databricksToken.expiresAt > Date.now() + 60_000) {
      return this.databricksToken.value;
    }
    this.databricksTokenRequest ??= this.requestDatabricksToken(provider);
    try {
      this.databricksToken = await this.databricksTokenRequest;
      return this.databricksToken.value;
    } finally {
      this.databricksTokenRequest = undefined;
    }
  }

  private async requestDatabricksToken(
    provider: Extract<ProviderConfig, { backend: "databricks" }>,
  ): Promise<CachedToken> {
    let response: Response;
    try {
      response = await this.transport(provider.tokenUrl, {
        method: "POST",
        headers: {
          authorization: `Basic ${btoa(`${provider.clientId}:${provider.clientSecret}`)}`,
          "content-type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({ grant_type: "client_credentials", scope: "all-apis" }),
        signal: AbortSignal.timeout(DATABRICKS_TOKEN_TIMEOUT_MS),
      });
    } catch {
      throw new GatewayRequestError("Databricks authentication failed", 502, "provider_authentication_failed");
    }
    const body: unknown = await response.json().catch(() => undefined);
    if (
      !response.ok
      || !body
      || typeof body !== "object"
      || !("access_token" in body)
      || typeof body.access_token !== "string"
      || !("expires_in" in body)
      || typeof body.expires_in !== "number"
    ) {
      throw new GatewayRequestError("Databricks authentication failed", 502, "provider_authentication_failed");
    }
    return { value: body.access_token, expiresAt: Date.now() + body.expires_in * 1000 };
  }

  private assertRequestCanBeRead(request: Request): void {
    const contentEncoding = request.headers.get("content-encoding");
    if (contentEncoding && contentEncoding.toLowerCase() !== "identity") {
      throw new GatewayRequestError(
        "Compressed request bodies are not supported; set features.enable_request_compression = false in Codex config.toml",
        415,
        "unsupported_content_encoding",
      );
    }
    const contentLength = request.headers.get("content-length");
    if (contentLength && Number(contentLength) > this.config.maxRequestBytes) {
      throw new GatewayRequestError("Request body is too large", 413, "request_too_large");
    }
  }
}

async function parseBoundedJsonObject(request: Request, maximumBytes: number): Promise<Record<string, unknown>> {
  const rawBody = await readBoundedBody(request, maximumBytes);
  let body: unknown;
  try {
    body = JSON.parse(rawBody);
  } catch {
    throw new GatewayRequestError("Request body must be valid JSON", 400, "invalid_json");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new GatewayRequestError("Request body must be a JSON object", 400, "invalid_request");
  }
  return body as Record<string, unknown>;
}

async function readBoundedBody(request: Request, maximumBytes: number): Promise<string> {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let body = "";
  let byteLength = 0;
  while (true) {
    const result = await reader.read();
    if (result.done) break;
    byteLength += result.value.byteLength;
    if (byteLength > maximumBytes) {
      await reader.cancel();
      throw new GatewayRequestError("Request body is too large", 413, "request_too_large");
    }
    body += decoder.decode(result.value, { stream: true });
  }
  return body + decoder.decode();
}

function proxyUpstreamResponse(upstream: Response): Response {
  const headers = new Headers({
    "cache-control": "no-store",
    "x-accel-buffering": "no",
  });
  for (const name of [
    "content-type",
    "retry-after",
    "request-id",
    "x-request-id",
    "x-ratelimit-limit-requests",
    "x-ratelimit-remaining-requests",
    "x-ratelimit-reset-requests",
  ]) {
    const value = upstream.headers.get(name);
    if (value) headers.set(name, value);
  }
  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers,
  });
}

export function gatewayError(error: GatewayRequestError): Response {
  return Response.json(
    {
      error: {
        message: error.message,
        type: "invalid_request_error",
        code: error.code,
      },
    },
    { status: error.status },
  );
}

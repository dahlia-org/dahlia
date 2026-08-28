import type { AuthStore } from "../auth/store";
import type { AppConfig } from "../config";
import { listDatabricksModelServices, sendOpenAIResponses, type GatewayFetch } from "./adapters";
import { MODEL_ALIAS_PATTERN } from "./model-alias";

interface DatabricksModel {
  id: string;
  displayName: string | null;
}

const DATABRICKS_MODEL_TIMEOUT_MS = 30_000;

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
  constructor(
    private readonly config: AppConfig,
    private readonly store: Pick<AuthStore, "getEnabledModelAlias" | "listModelAliases">,
    private readonly transport: GatewayFetch = fetch,
  ) {}

  async models() {
    if (!this.config.provider) return { object: "list", data: [] };
    const aliases = await this.modelAliases();
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

  async adminModels(request: Request) {
    const aliases = await this.modelAliases();
    if (this.config.provider?.backend !== "databricks") {
      return aliases.map((alias) => ({ ...alias, configured: true }));
    }
    const models = await this.databricksModels(request);
    return models.map((model) => {
      const configured = aliases.find((alias) => alias.upstreamModel === model.id);
      return configured
        ? { ...configured, configured: true }
        : {
            alias: databricksModelAlias(model.id),
            upstreamModel: model.id,
            displayName: model.displayName,
            enabled: false,
            configured: false,
          };
    });
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
      ? forwardedDatabricksAuthorization(request)
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

  private async modelAliases() {
    try {
      return await this.store.listModelAliases();
    } catch {
      throw new GatewayRequestError("Model registry is unavailable", 503, "model_registry_unavailable");
    }
  }

  private async databricksModels(request: Request): Promise<DatabricksModel[]> {
    const provider = this.config.provider;
    if (provider?.backend !== "databricks") return [];
    const authorization = forwardedDatabricksAuthorization(request);
    const signal = AbortSignal.any([request.signal, AbortSignal.timeout(DATABRICKS_MODEL_TIMEOUT_MS)]);
    const models: DatabricksModel[] = [];
    const pageTokens = new Set<string>();
    let pageToken: string | undefined;
    do {
      const response = await listDatabricksModelServices(
        provider,
        authorization,
        signal,
        this.transport,
        pageToken,
      ).catch(() => {
        throw new GatewayRequestError("Databricks model list is unavailable", 502, "provider_models_unavailable");
      });
      if (!response.ok) {
        throw new GatewayRequestError("Databricks model list is unavailable", 502, "provider_models_unavailable");
      }
      const body: unknown = await response.json().catch(() => undefined);
      if (!body || typeof body !== "object" || !("model_services" in body) || !Array.isArray(body.model_services)) {
        throw new GatewayRequestError("Databricks model list is invalid", 502, "provider_models_invalid");
      }
      const modelServices = body.model_services as unknown[];
      for (const entry of modelServices) {
        if (!entry || typeof entry !== "object" || !("name" in entry) || typeof entry.name !== "string") {
          throw new GatewayRequestError("Databricks model list is invalid", 502, "provider_models_invalid");
        }
        const resourceName = entry.name.trim();
        const prefix = "model-services/";
        const id = resourceName.startsWith(prefix) ? resourceName.slice(prefix.length) : "";
        if (!id.startsWith("system.ai.") || id.length > 255 || !MODEL_ALIAS_PATTERN.test(databricksModelAlias(id))) {
          throw new GatewayRequestError("Databricks model list is invalid", 502, "provider_models_invalid");
        }
        models.push({ id, displayName: null });
      }
      const nextPageToken: unknown = "next_page_token" in body ? body.next_page_token : undefined;
      if (nextPageToken !== undefined && typeof nextPageToken !== "string") {
        throw new GatewayRequestError("Databricks model list is invalid", 502, "provider_models_invalid");
      }
      pageToken = nextPageToken?.trim() || undefined;
      if (pageToken && pageTokens.has(pageToken)) {
        throw new GatewayRequestError("Databricks model list is invalid", 502, "provider_models_invalid");
      }
      if (pageToken) pageTokens.add(pageToken);
    } while (pageToken);
    return models;
  }
}

function databricksModelAlias(id: string): string {
  return id.startsWith("system.ai.") ? id.slice("system.ai.".length) : id;
}

function forwardedDatabricksAuthorization(request: Request): string {
  const token = request.headers.get("x-forwarded-access-token")?.trim();
  if (!token) {
    throw new GatewayRequestError(
      "Databricks access token is unavailable",
      401,
      "databricks_access_token_required",
    );
  }
  return `Bearer ${token}`;
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

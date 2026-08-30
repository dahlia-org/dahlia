import type { AuthStore } from "../auth/store";
import type { AppConfig } from "../config";
import { DatabricksTokenProvider } from "../databricks/token";
import { listDatabricksModelServices, sendOpenAIResponses, type GatewayFetch } from "./adapters";
import { MODEL_ALIAS_PATTERN } from "./model-alias";

interface DatabricksModel {
  id: string;
  displayName: string | null;
  updateTime?: string;
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
  private readonly databricksTokens?: DatabricksTokenProvider;

  constructor(
    private readonly config: AppConfig,
    private readonly store: Pick<AuthStore, "getEnabledModelAlias" | "listModelAliases">,
    private readonly transport: GatewayFetch = fetch,
  ) {
    if (config.provider?.backend === "databricks") {
      if (!config.databricksWorkspace) throw new Error("Databricks workspace credentials are required");
      this.databricksTokens = new DatabricksTokenProvider(config.databricksWorkspace, transport);
    }
  }

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
    const usedAliases = new Set(aliases.map((alias) => alias.alias));
    return models.map((model) => {
      const configured = aliases.find((alias) => alias.upstreamModel === model.id);
      return configured
        ? { ...configured, updateTime: model.updateTime, configured: true }
        : {
            alias: availableDatabricksModelAlias(model.id, usedAliases),
            upstreamModel: model.id,
            displayName: model.displayName,
            updateTime: model.updateTime,
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
    const deadline = AbortSignal.timeout(DATABRICKS_MODEL_TIMEOUT_MS);
    let token: string;
    try {
      token = await this.databricksTokens!.getToken();
    } catch (error) {
      throw databricksModelListError("provider_models_unavailable", "authentication_error", {
        errorName: error instanceof Error ? error.name : "UnknownError",
      });
    }
    const authorization = `Bearer ${token}`;
    const signal = AbortSignal.any([request.signal, deadline]);
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
      if (!body || typeof body !== "object" || !("model_services" in body) || !Array.isArray(body.model_services)) {
        throw databricksModelListError("provider_models_invalid", "invalid_response_shape", { requestId });
      }
      const modelServices = body.model_services as unknown[];
      for (const entry of modelServices) {
        if (!entry || typeof entry !== "object" || !("name" in entry) || typeof entry.name !== "string") {
          throw databricksModelListError("provider_models_invalid", "invalid_model_entry", { requestId });
        }
        const resourceName = entry.name.trim();
        const prefix = "model-services/";
        const id = resourceName.startsWith(prefix) ? resourceName.slice(prefix.length) : "";
        if (!id.startsWith("system.ai.") || !MODEL_ALIAS_PATTERN.test(databricksModelAlias(id))) {
          throw databricksModelListError("provider_models_invalid", "invalid_model_name", { requestId });
        }
        const updateTime = "update_time" in entry && typeof entry.update_time === "string"
          ? entry.update_time
          : undefined;
        models.push({ id, displayName: null, updateTime });
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
    return models;
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

function databricksModelAlias(id: string): string {
  return id.startsWith("system.ai.") ? id.slice("system.ai.".length) : id;
}

function availableDatabricksModelAlias(id: string, usedAliases: Set<string>): string {
  const preferred = databricksModelAlias(id);
  if (!usedAliases.has(preferred)) {
    usedAliases.add(preferred);
    return preferred;
  }
  for (let index = 2; ; index++) {
    const suffix = `-${index}`;
    const candidate = `${preferred.slice(0, 255 - suffix.length)}${suffix}`;
    if (!usedAliases.has(candidate)) {
      usedAliases.add(candidate);
      return candidate;
    }
  }
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

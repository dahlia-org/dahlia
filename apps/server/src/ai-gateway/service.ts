import type { AppConfig } from "../config";
import type { GatewayFetch } from "./adapters";
import type { AIGatewayBackend, RequestBody, RequestContext } from "./backend";
import { DatabricksBackend } from "./databricks";
import { OpenAIBackend } from "./openai";
import { CloudflareBackend } from "./cloudflare";
import { GatewayRequestError } from "./errors";
import { CODEX_AUTO_REVIEW_ALIAS } from "./model-alias";
import { modelList } from "./models";

export { GatewayRequestError } from "./errors";
export const LATEST_CODEX_CLIENT_VERSION = "0.149.1";

export class GatewayService {
  private readonly backend?: AIGatewayBackend;

  constructor(
    private readonly config: AppConfig,
    transport: GatewayFetch = fetch,
  ) {
    const provider = config.provider;
    if (provider?.backend === "databricks") {
      if (!config.databricksWorkspace) throw new Error("Databricks workspace credentials are required");
      this.backend = new DatabricksBackend(provider, config.databricksWorkspace, transport);
    } else if (provider) {
      this.backend = provider.backend === "cloudflare"
        ? new CloudflareBackend(provider, transport)
        : new OpenAIBackend(provider, transport);
    }
  }

  async models(request?: Request) {
    requireSupportedCodexClient(request);
    if (!this.backend) return modelList([]);
    const result = await this.backend.listModels({ signal: request?.signal ?? new AbortController().signal });
    const configured = this.config.codexAutoReviewModel?.trim();
    // The reserved Server override is the only change to the backend's model list.
    const override = modelList(configured ? [{ id: CODEX_AUTO_REVIEW_ALIAS, displayName: "Codex Auto Review" }] : []);
    return {
      ...result,
      data: [...result.data.filter((entry) => entry.id !== CODEX_AUTO_REVIEW_ALIAS), ...override.data],
      models: [
        ...result.models.filter((entry) => entry.slug !== CODEX_AUTO_REVIEW_ALIAS),
        ...override.models.filter((entry) => entry.slug === CODEX_AUTO_REVIEW_ALIAS),
      ],
    };
  }

  async responses(request: Request, identity: RequestContext["identity"]): Promise<Response> {
    this.assertRequestCanBeRead(request);
    const body = await parseBoundedJsonObject(request, this.config.maxRequestBytes);
    if (typeof body.model !== "string" || !body.model.trim()) {
      throw new GatewayRequestError("model is required", 400, "model_required");
    }
    const validInput = body.input === undefined || typeof body.input === "string"
      || (Array.isArray(body.input) && body.input.every(
        (item) => item !== null && typeof item === "object" && !Array.isArray(item),
      ));
    if (
      !validInput
      || (body.stream != null && typeof body.stream !== "boolean")
      || (body.max_output_tokens != null
        && (!Number.isSafeInteger(body.max_output_tokens) || Number(body.max_output_tokens) <= 0))
    ) {
      throw new GatewayRequestError("Invalid Responses request", 400, "invalid_request");
    }
    if (!this.backend) throw new GatewayRequestError("AI provider is not configured", 503, "provider_not_configured");
    let upstreamModel: string | undefined;
    if (body.model === CODEX_AUTO_REVIEW_ALIAS) {
      upstreamModel = this.config.codexAutoReviewModel?.trim();
      if (!upstreamModel) throw new GatewayRequestError("Model is not available", 404, "model_not_found");
    }
    return proxyUpstreamResponse(await this.backend.responses(body as RequestBody, {
      identity: { userId: identity.userId }, headers: request.headers, signal: request.signal, upstreamModel,
    }));
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

function requireSupportedCodexClient(request?: Request): void {
  if (!request) return;
  const version = new URL(request.url).searchParams.get("client_version")
    ?? LATEST_CODEX_CLIENT_VERSION;
  if (version !== LATEST_CODEX_CLIENT_VERSION) {
    throw new GatewayRequestError(
      `Codex client version '${version}' is not supported`,
      400,
      "unsupported_codex_client_version",
    );
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

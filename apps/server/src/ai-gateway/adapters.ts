import type { ProviderConfig } from "../config";

export type GatewayFetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export interface UpstreamRequest {
  body: string;
  requestHeaders: Headers;
  signal?: AbortSignal;
}

function upstreamHeaders(requestHeaders: Headers, authorization: string): Headers {
  const headers = new Headers({
    accept: requestHeaders.get("accept") || "text/event-stream, application/json",
    authorization,
    "content-type": "application/json",
    "user-agent": "dahlia-server/0.1",
  });
  for (const name of ["idempotency-key", "openai-beta"]) {
    const value = requestHeaders.get(name);
    if (value) headers.set(name, value);
  }
  return headers;
}

export function sendOpenAIResponses(
  provider: ProviderConfig,
  authorization: string,
  request: UpstreamRequest,
  transport: GatewayFetch = fetch,
): Promise<Response> {
  const headers = upstreamHeaders(request.requestHeaders, authorization);
  if (provider.backend === "cloudflare") headers.set("cf-aig-collect-log-payload", "false");
  const endpoint = new URL(provider.baseUrl);
  endpoint.pathname = `${endpoint.pathname.replace(/\/$/, "")}/responses`;
  return transport(endpoint, {
    method: "POST",
    headers,
    body: request.body,
    signal: request.signal,
  });
}

export function listDatabricksModels(
  provider: Extract<ProviderConfig, { backend: "databricks" }>,
  authorization: string,
  signal?: AbortSignal,
  transport: GatewayFetch = fetch,
): Promise<Response> {
  const endpoint = new URL(provider.baseUrl);
  endpoint.pathname = `${endpoint.pathname.replace(/\/$/, "")}/models`;
  return transport(endpoint, {
    cache: "no-store",
    headers: {
      accept: "application/json",
      authorization,
      "user-agent": "dahlia-server/0.1",
    },
    signal,
  });
}

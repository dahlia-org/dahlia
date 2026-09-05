import type { ProviderConfig } from "../config";

export type GatewayFetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export interface UpstreamRequest {
  body: string;
  requestHeaders: Headers;
  signal?: AbortSignal;
  upstreamHeaders?: Record<string, string>;
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
  for (const [name, value] of Object.entries(request.upstreamHeaders ?? {})) headers.set(name, value);
  const endpoint = new URL(provider.baseUrl);
  endpoint.pathname = `${endpoint.pathname.replace(/\/$/, "")}/responses`;
  return transport(endpoint, {
    method: "POST",
    headers,
    body: request.body,
    signal: request.signal,
  });
}

export function listDatabricksModelServices(
  provider: Extract<ProviderConfig, { backend: "databricks" }>,
  authorization: string,
  signal?: AbortSignal,
  transport: GatewayFetch = fetch,
  pageToken?: string,
): Promise<Response> {
  const endpoint = new URL("/api/2.1/unity-catalog/model-services", provider.baseUrl);
  endpoint.searchParams.set("parent", `schemas/${provider.modelSchema}`);
  endpoint.searchParams.set("view", "BASIC");
  endpoint.searchParams.set("page_size", "100");
  if (pageToken) endpoint.searchParams.set("page_token", pageToken);
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

import { describe, expect, it, vi } from "vitest";

import { CloudflareBackend } from "../src/ai-gateway/cloudflare";
import type { ProviderConfig } from "../src/config";
import { listDatabricksModelServices, sendOpenAIResponses, type GatewayFetch } from "../src/ai-gateway/adapters";

const provider: ProviderConfig = {
  backend: "openai",
  baseUrl: "https://openai.example/v1",
  apiKey: "provider-secret",
};

describe("gateway adapter contract", () => {
  it("uses the OpenAI Responses endpoint without leaking the key into the body", async () => {
    const transport = vi.fn<GatewayFetch>(async () => new Response("{}"));
    await sendOpenAIResponses(provider, "Bearer provider-secret", {
      body: '{"model":"upstream-model"}',
      requestHeaders: new Headers({
        "idempotency-key": "request-1",
        "openai-beta": "responses=v1",
        "x-forwarded-access-token": "user-token",
      }),
    }, transport);

    const [url, init] = transport.mock.calls[0]!;
    const headers = new Headers(init?.headers);
    expect(String(url)).toBe("https://openai.example/v1/responses");
    expect(headers.get("authorization")).toBe("Bearer provider-secret");
    expect(headers.get("idempotency-key")).toBe("request-1");
    expect(headers.get("openai-beta")).toBe("responses=v1");
    expect([...headers.values()]).not.toContain("user-token");
    expect(String(init?.body)).not.toContain("provider-secret");
  });

  it("disables Cloudflare payload logging without adding gateway selection headers", async () => {
    const transport = vi.fn<GatewayFetch>(async () => new Response("{}"));
    await new CloudflareBackend({ ...provider, backend: "cloudflare" }, transport).responses(
      { model: "openai/gpt-5.6-luna", input: [] },
      { headers: new Headers(), identity: { userId: "user" }, signal: new AbortController().signal },
    );

    const headers = new Headers(transport.mock.calls[0]![1]?.headers);
    expect(headers.get("cf-aig-collect-log-payload")).toBe("false");
    expect(headers.has("cf-aig-gateway-id")).toBe(false);
    expect(headers.has("databricks-model-provider-service")).toBe(false);
  });

  it("lists Databricks models with only the Bearer credential", async () => {
    const transport = vi.fn<GatewayFetch>(async () => new Response('{"model_services":[]}'));
    await listDatabricksModelServices(
      { backend: "databricks", modelSchema: "dahlia.ai", baseUrl: "https://workspace.example/ai-gateway/mlflow/v1" },
      "Bearer user-token",
      undefined,
      transport,
      "next/token",
    );

    const [url, init] = transport.mock.calls[0]!;
    const headers = new Headers(init?.headers);
    const endpoint = new URL(String(url));
    expect(endpoint.origin + endpoint.pathname)
      .toBe("https://workspace.example/api/2.1/unity-catalog/model-services");
    expect(Object.fromEntries(endpoint.searchParams)).toEqual({
      parent: "schemas/dahlia.ai",
      view: "BASIC",
      page_size: "100",
      page_token: "next/token",
    });
    expect(init?.method).toBeUndefined();
    expect(init?.cache).toBe("no-store");
    expect(headers.get("authorization")).toBe("Bearer user-token");
    expect(headers.has("x-forwarded-access-token")).toBe(false);
  });
});

import { describe, expect, it, vi } from "vitest";

import { CloudflareBackend } from "../src/ai-gateway/cloudflare";
import type { ProviderConfig } from "../src/config";
import { sendOpenAIResponses, type GatewayFetch } from "../src/ai-gateway/adapters";

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

  it("disables Cloudflare payload logging and selects the default gateway", async () => {
    const transport = vi.fn<GatewayFetch>(async () => new Response("{}"));
    const backend = new CloudflareBackend({ ...provider, backend: "cloudflare" }, transport);
    expect((await backend.listModels({ signal: new AbortController().signal })).data).toEqual([]);
    await backend.responses(
      { model: "openai/gpt-5.6-luna", input: [] },
      { headers: new Headers(), identity: { userId: "user" }, signal: new AbortController().signal },
    );

    const headers = new Headers(transport.mock.calls[0]![1]?.headers);
    expect(headers.get("cf-aig-collect-log-payload")).toBe("false");
    expect(headers.get("cf-aig-gateway-id")).toBe("default");
    expect(headers.has("databricks-model-provider-service")).toBe(false);
  });
});

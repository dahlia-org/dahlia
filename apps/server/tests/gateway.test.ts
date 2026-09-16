import { testUserID } from "./public-test-client";
import { describe, expect, it, vi } from "vitest";

import type { AppConfig } from "../src/config";
import type { GatewayFetch } from "../src/ai-gateway/adapters";
import { GatewayService, LATEST_CODEX_CLIENT_VERSION } from "../src/ai-gateway/service";
import { DatabricksBackend } from "../src/ai-gateway/databricks";
import { createApp } from "../src/app";
import { testStore } from "./test-store";

const config: AppConfig = {
  authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite",
  baseUrl: "https://dahlia.example", oauthRedirectUris: [], maxRequestBytes: 1024,
  provider: { backend: "openai", baseUrl: "https://upstream.example/v1", apiKey: "secret" },
  codexModels: ["gpt-5.6-luna"],
};
const databricksProvider = {
  backend: "databricks" as const, baseUrl: "https://workspace.example/ai-gateway/mlflow/v1",
};
const databricksConfig: AppConfig = {
  ...config,
  provider: databricksProvider,
  codexModels: ["system.ai.gpt-5-6-luna", "system.ai.custom"],
};
const identity = { userId: "verified-user" };
const request = (body: unknown, headers?: HeadersInit) => new Request("https://dahlia.example/api/v1/responses", {
  method: "POST", headers, body: JSON.stringify(body),
});
const configs: AppConfig[] = [config, {
  ...config, provider: { backend: "cloudflare", baseUrl: "https://cf.example/v1", apiKey: "secret" },
  codexModels: ["gpt-5.6-luna", "gpt-4.1", "gemini-3-flash"],
}, databricksConfig];

describe("AI Gateway", () => {
  it.each(configs)("keeps auto review override independent of backend ($provider.backend)", async (backendConfig) => {
    const sent = vi.fn<GatewayFetch>(async () => new Response("{}"));
    const service = new GatewayService({ ...backendConfig, codexAutoReviewModel: "other.schema.reviewer" }, sent);
    const models = await service.models();
    expect(models.data.filter((m) => m.id === "codex-auto-review")).toHaveLength(1);
    expect(models.models.filter((m) => m.slug === "codex-auto-review")).toHaveLength(1);
    expect(models.models.find((m) => m.slug === "codex-auto-review")).toMatchObject({ visibility: "list", display_name: "Codex Auto Review" });
    await service.responses(request({ model: "codex-auto-review", input: [], stream: true }, {
      "x-forwarded-access-token": "user-token",
    }), identity);
    expect(JSON.parse(String(sent.mock.calls.at(-1)![1]?.body))).toMatchObject({ model: "other.schema.reviewer" });

    for (const value of [undefined, " "]) {
      const fallback = new GatewayService({ ...backendConfig, codexAutoReviewModel: value }, sent);
      const list = await fallback.models();
      expect(list.data.some((m) => m.id === "codex-auto-review")).toBe(false);
      expect(list.models.find((m) => m.slug === "codex-auto-review")?.visibility).toBeUndefined();
      await expect(fallback.responses(request({ model: "codex-auto-review", input: [] }, {
        "x-forwarded-access-token": "user-token",
      }), identity)).rejects.toMatchObject({ status: 400, code: "model_not_configured" });
    }
  });

  it.each(configs)("uses the configured model list without provider discovery ($provider.backend)", async (backendConfig) => {
    const transport = vi.fn<GatewayFetch>();
    const models = await new GatewayService(backendConfig, transport).models();
    expect(models.data.map((m) => m.id)).toEqual(backendConfig.codexModels);
    expect(transport).not.toHaveBeenCalled();
  });

  it.each(configs)("publishes nothing when the model list is unset ($provider.backend)", async (backendConfig) => {
    expect((await new GatewayService({ ...backendConfig, codexModels: undefined }).models()).data).toEqual([]);
  });

  it.each(configs)("rejects models outside the configured list ($provider.backend)", async (backendConfig) => {
    const transport = vi.fn<GatewayFetch>();
    await expect(new GatewayService(backendConfig, transport).responses(request({ model: "unconfigured", input: [] }, {
      "x-forwarded-access-token": "user-token",
    }), identity)).rejects.toMatchObject({ status: 400, code: "model_not_configured" });
    expect(transport).not.toHaveBeenCalled();
  });

  it("publishes fully qualified Databricks slugs with Codex metadata", async () => {
    const transport = vi.fn<GatewayFetch>();
    const list = await new GatewayService(databricksConfig, transport).models(
      new Request(`https://dahlia.example/api/v1/models?client_version=${LATEST_CODEX_CLIENT_VERSION}`, {
        headers: { "x-forwarded-access-token": "must-not-use" },
      }),
    );
    expect(list.data.map((m) => m.id)).toEqual(["system.ai.gpt-5-6-luna", "system.ai.custom"]);
    expect(list.data.map((m) => m.display_name)).toEqual(["GPT 5.6 Luna", "system.ai.custom"]);
    expect(list.models.find((m) => m.slug === "system.ai.gpt-5-6-luna"))
      .toMatchObject({ default_reasoning_level: "medium", visibility: "list", display_name: "GPT 5.6 Luna" });
    expect(list.models.find((m) => m.slug === "system.ai.custom")).toBeUndefined();
    expect(transport).not.toHaveBeenCalled();
  });

  it("maps the Cloudflare mock ID while preserving the rest of the request", async () => {
    const transport = vi.fn<GatewayFetch>(async () => new Response("{}"));
    await new GatewayService(configs[1]!, transport).responses(request({ model: "gpt-5.6-luna", input: "hello", max_output_tokens: 256 }), identity);
    expect(JSON.parse(String(transport.mock.calls[0]![1]?.body))).toEqual({ model: "openai/gpt-5.6-luna", input: "hello", max_output_tokens: 256 });
    expect(new Headers(transport.mock.calls[0]![1]?.headers).get("cf-aig-collect-log-payload")).toBe("false");
  });

  it("does not mutate the body; resolves model, OBO and trusted user tags inside Databricks", async () => {
    const transport = vi.fn<GatewayFetch>(async () => new Response("{}"));
    const backend = new DatabricksBackend(databricksProvider, databricksConfig.codexModels!, transport);
    const body = Object.freeze({ model: "system.ai.gpt-5-6-luna", input: [], max_output_tokens: 256, stream: true, tools: [{ type: "function", name: "note" }] });
    const controller = new AbortController();
    await backend.responses(body, {
      identity, signal: controller.signal,
      headers: new Headers({ "x-forwarded-access-token": "obo", "Databricks-Ai-Gateway-Request-Tags": '{"user_id":"forged"}', "x-user-id": "forged" }),
    });
    const [url, init] = transport.mock.calls[0]!;
    expect(String(url)).toBe(`${databricksProvider.baseUrl}/responses`);
    expect(JSON.parse(String(init?.body))).toEqual(body);
    expect(body.model).toBe("system.ai.gpt-5-6-luna");
    const headers = new Headers(init?.headers);
    expect(headers.get("authorization")).toBe("Bearer obo");
    expect(headers.get("Databricks-Ai-Gateway-Request-Tags")).toBe('{"user_id":"verified-user"}');
    expect(headers.has("x-forwarded-access-token")).toBe(false);
    expect(headers.has("x-user-id")).toBe(false);
    expect(init?.signal).toBe(controller.signal);
    controller.abort();
    expect(init?.signal?.aborted).toBe(true);
  });

  it("uses API identity instead of body or client tag fields", async () => {
    const transport = vi.fn<GatewayFetch>(async () => new Response("{}"));
    const app = createApp({ config: databricksConfig, authStore: testStore(), fetch: transport });
    const response = await app.request("/api/v1/responses", {
      method: "POST", headers: { "X-Forwarded-Email": "real@example.com", "x-forwarded-access-token": "obo" },
      body: JSON.stringify({ model: "system.ai.gpt-5-6-luna", input: [], identity: { userId: "forged" }, upstreamModel: "other.ai.model" }),
    });
    expect(response.status).toBe(200);
    expect(new Headers(transport.mock.calls[0]![1]?.headers).get("Databricks-Ai-Gateway-Request-Tags")).toBe(JSON.stringify({ user_id: testUserID("real@example.com") }));
    expect(JSON.parse(String(transport.mock.calls[0]![1]?.body))).toMatchObject({ model: "system.ai.gpt-5-6-luna" });
  });

  it("requires OBO before sending a fully qualified model", async () => {
    const transport = vi.fn<GatewayFetch>();
    const service = new GatewayService(databricksConfig, transport);
    await expect(service.responses(request({ model: "system.ai.gpt-5-6-luna", input: [] }), identity)).rejects.toMatchObject({ status: 401 });
    expect(transport).not.toHaveBeenCalled();
  });

  it("streams incrementally and preserves upstream status and safe headers", async () => {
    let streamController!: ReadableStreamDefaultController<Uint8Array>;
    const stream = new ReadableStream<Uint8Array>({ start(controller) { streamController = controller; } });
    const service = new GatewayService(config, async () => new Response(stream, {
      status: 429, headers: { "content-type": "text/event-stream", "retry-after": "3", "set-cookie": "private" },
    }));
    const response = await service.responses(request({ model: "gpt-5.6-luna", input: [], stream: true }), identity);
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("3");
    expect(response.headers.get("x-accel-buffering")).toBe("no");
    expect(response.headers.has("set-cookie")).toBe(false);
    streamController.enqueue(new TextEncoder().encode("data: first\n\n"));
    const reader = response.body!.getReader();
    expect(new TextDecoder().decode((await reader.read()).value)).toBe("data: first\n\n");
    streamController.close();
    expect((await reader.read()).done).toBe(true);
  });

  it.each(configs)("preserves optional Responses fields ($provider.backend)", async (backendConfig) => {
    const transport = vi.fn<GatewayFetch>(async () => new Response("{}"));
    const service = new GatewayService(backendConfig, transport);
    const model = backendConfig.codexModels![0]!;
    for (const body of [
      { model, input: [], max_output_tokens: null },
      { model, input: [], stream: null },
      { model, prompt: { id: "pmpt_example" } },
    ]) {
      await service.responses(request(body, { "x-forwarded-access-token": "obo" }), identity);
      expect(JSON.parse(String(transport.mock.calls.at(-1)![1]?.body))).toEqual({
        ...body,
        model: backendConfig.provider?.backend === "cloudflare" ? `openai/${model}` : model,
      });
    }
  });

  it("rejects invalid input, compression, and excessive bytes without calling upstream", async () => {
    const transport = vi.fn<GatewayFetch>();
    const service = new GatewayService(config, transport);
    for (const body of [{ input: [] }, { model: "gpt-5.6-luna", input: 1 }, { model: "gpt-5.6-luna", input: [null] }, { model: "gpt-5.6-luna", input: [], stream: "true" }, { model: "gpt-5.6-luna", input: [], max_output_tokens: -1 }]) {
      await expect(service.responses(request(body), identity)).rejects.toMatchObject({ status: 400 });
    }
    await expect(service.responses(request({}, { "content-encoding": "zstd" }), identity)).rejects.toMatchObject({ status: 415 });
    await expect(service.responses(request("x".repeat(1025)), identity)).rejects.toMatchObject({ status: 413 });
    await expect(service.responses(request({}, { "content-length": "1025" }), identity)).rejects.toMatchObject({ status: 413 });
    await expect(service.responses(new Request("https://dahlia.example", { method: "POST", body: "{" }), identity)).rejects.toMatchObject({ code: "invalid_json" });
    await expect(service.models(new Request("https://dahlia.example/api/v1/models?client_version=old"))).rejects.toMatchObject({ code: "unsupported_codex_client_version" });
    expect(transport).not.toHaveBeenCalled();
  });

  it("returns empty discovery and a clear error when no backend is configured", async () => {
    const service = new GatewayService({ ...config, provider: undefined });
    expect((await service.models()).data).toEqual([]);
    await expect(service.responses(request({ model: "model", input: [] }), identity)).rejects.toMatchObject({ status: 503, code: "provider_not_configured" });
  });
});

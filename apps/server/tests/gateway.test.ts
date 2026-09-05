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
};
const databricksProvider = {
  backend: "databricks" as const, modelSchema: "dahlia.ai", baseUrl: "https://workspace.example/ai-gateway/mlflow/v1",
};
const workspace = {
  host: "https://workspace.example", clientId: "app-client-id", clientSecret: "app-client-secret",
  tokenUrl: "https://workspace.example/oidc/v1/token",
};
const databricksConfig: AppConfig = { ...config, provider: databricksProvider, databricksWorkspace: workspace };
const identity = { userId: "verified-user" };
const request = (body: unknown, headers?: HeadersInit) => new Request("https://dahlia.example/api/v1/responses", {
  method: "POST", headers, body: JSON.stringify(body),
});
const modelTransport = (models: GatewayFetch): GatewayFetch => async (url, init) =>
  String(url).endsWith("/oidc/v1/token")
    ? Response.json({ access_token: "app-token", expires_in: 3600 }) : models(url, init);

const configs: AppConfig[] = [config, {
  ...config, provider: { backend: "cloudflare", baseUrl: "https://cf.example/v1", apiKey: "secret" },
}, databricksConfig];

describe("AI Gateway", () => {
  it.each(configs)("keeps auto review override independent of backend ($provider.backend)", async (backendConfig) => {
    const sent = vi.fn<GatewayFetch>(async (url) => String(url).includes("model-services")
      ? Response.json({ model_services: [{ name: "model-services/dahlia.ai.codex-auto-review" }] })
      : new Response("{}"));
    const service = new GatewayService({ ...backendConfig, codexAutoReviewModel: "other.schema.reviewer" }, modelTransport(sent));
    const models = await service.models();
    expect(models.data.filter((m) => m.id === "codex-auto-review")).toHaveLength(1);
    expect(models.models.filter((m) => m.slug === "codex-auto-review")).toHaveLength(1);
    expect(models.models.find((m) => m.slug === "codex-auto-review")).toMatchObject({ visibility: "list", display_name: "Codex Auto Review" });
    await service.responses(request({ model: "codex-auto-review", input: [], stream: true }, {
      "x-forwarded-access-token": "user-token",
    }), identity);
    expect(JSON.parse(String(sent.mock.calls.at(-1)![1]?.body))).toMatchObject({ model: "other.schema.reviewer" });

    for (const value of [undefined, " "]) {
      const disabled = new GatewayService({ ...backendConfig, codexAutoReviewModel: value }, modelTransport(sent));
      const list = await disabled.models();
      expect(list.data.some((m) => m.id === "codex-auto-review")).toBe(false);
      expect(list.models.find((m) => m.slug === "codex-auto-review")?.visibility).toBe("hide");
      await expect(disabled.responses(request({ model: "codex-auto-review", input: [] }), identity))
        .rejects.toMatchObject({ status: 404, code: "model_not_found" });
    }
  });

  it.each(configs.slice(0, 2))("uses a mock list without reading the database ($provider.backend)", async (backendConfig) => {
    const transport = vi.fn<GatewayFetch>();
    const models = await new GatewayService(backendConfig, transport).models();
    expect(models.data.map((m) => m.id)).toEqual(["gpt-5.6-luna"]);
    expect(models.models.find((m) => m.slug === "gpt-5.6-luna")).toMatchObject({ visibility: "list", input_modalities: ["text", "image"] });
    expect(transport).not.toHaveBeenCalled();
  });

  it("paginates the configured schema with the App credential and Codex metadata", async () => {
    const transport = vi.fn<GatewayFetch>(async (url, init) => {
      const endpoint = new URL(String(url));
      expect(endpoint.searchParams.get("parent")).toBe("schemas/dahlia.ai");
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer app-token");
      expect(init?.cache).toBe("no-store");
      return Response.json(endpoint.searchParams.has("page_token")
        ? { model_services: [{ name: "model-services/dahlia.ai.custom" }] }
        : { model_services: [{ name: "model-services/dahlia.ai.gpt-5-6-luna" }], next_page_token: "page-2" });
    });
    const list = await new GatewayService(databricksConfig, modelTransport(transport)).models(
      new Request(`https://dahlia.example/api/v1/models?client_version=${LATEST_CODEX_CLIENT_VERSION}`, {
        headers: { "x-forwarded-access-token": "must-not-use" },
      }),
    );
    expect(list.data.map((m) => m.id)).toEqual(["gpt-5-6-luna", "custom"]);
    expect(list.models.find((m) => m.slug === "gpt-5-6-luna")).toMatchObject({ default_reasoning_level: "medium", visibility: "list" });
    expect(list.models.find((m) => m.slug === "gpt-5-6-luna")).not.toHaveProperty("use_responses_lite");
    expect(list.models.find((m) => m.slug === "custom")?.supported_reasoning_levels.map((l) => l.effort)).toEqual(["none", "low", "high", "max"]);
    expect(transport).toHaveBeenCalledTimes(2);
  });

  it("accepts an empty protobuf model list", async () => {
    const models = await new GatewayService(databricksConfig, modelTransport(async () => Response.json({}))).models();
    expect(models.data).toEqual([]);
  });

  it("maps the Cloudflare mock ID while preserving the rest of the request", async () => {
    const transport = vi.fn<GatewayFetch>(async () => new Response("{}"));
    await new GatewayService(configs[1]!, transport).responses(request({ model: "gpt-5.6-luna", input: "hello", max_output_tokens: 256 }), identity);
    expect(JSON.parse(String(transport.mock.calls[0]![1]?.body))).toEqual({ model: "openai/gpt-5.6-luna", input: "hello", max_output_tokens: 256 });
    expect(new Headers(transport.mock.calls[0]![1]?.headers).get("cf-aig-collect-log-payload")).toBe("false");
  });

  it.each([
    { model_services: [{ name: "model-services/other.ai.model" }] },
    { model_services: [{ name: "model-services/dahlia.ai.a.b" }] },
    { model_services: [null] },
    { model_services: [], next_page_token: 123 },
    { model_services: [], next_page_token: "repeated" },
    { model_services: "invalid" },
  ])("rejects malformed model discovery: %j", async (body) => {
    const logs = vi.spyOn(console, "error").mockImplementation(() => {});
    await expect(new GatewayService(databricksConfig, modelTransport(async () => Response.json(body))).models())
      .rejects.toMatchObject({ status: 502, code: "provider_models_invalid" });
    logs.mockRestore();
  });

  it("keeps upstream discovery errors private", async () => {
    const logs = vi.spyOn(console, "error").mockImplementation(() => {});
    const app = createApp({ config: databricksConfig, authStore: testStore(), fetch: modelTransport(async () => new Response("private body", { status: 403 })) });
    const response = await app.request("/api/v1/models", { headers: { "X-Forwarded-Email": "user@example.com" } });
    expect(response.status).toBe(502);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.text()).not.toContain("private body");
    expect(JSON.stringify(logs.mock.calls)).not.toContain("private body");
    logs.mockRestore();
  });

  it("does not mutate the body; resolves model, OBO and trusted user tags inside Databricks", async () => {
    const transport = vi.fn<GatewayFetch>(async () => new Response("{}"));
    const backend = new DatabricksBackend(databricksProvider, workspace, transport);
    const body = Object.freeze({ model: "gpt-5-6-luna", input: [], max_output_tokens: 256, stream: true, tools: [{ type: "function", name: "note" }] });
    const controller = new AbortController();
    await backend.responses(body, {
      identity, signal: controller.signal,
      headers: new Headers({ "x-forwarded-access-token": "obo", "Databricks-Ai-Gateway-Request-Tags": '{"user_id":"forged"}', "x-user-id": "forged" }),
    });
    const [url, init] = transport.mock.calls[0]!;
    expect(String(url)).toBe(`${databricksProvider.baseUrl}/responses`);
    expect(JSON.parse(String(init?.body))).toEqual({ ...body, model: "dahlia.ai.gpt-5-6-luna" });
    expect(body.model).toBe("gpt-5-6-luna");
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
      body: JSON.stringify({ model: "gpt-5-6-luna", input: [], identity: { userId: "forged" }, upstreamModel: "other.ai.model" }),
    });
    expect(response.status).toBe(200);
    expect(new Headers(transport.mock.calls[0]![1]?.headers).get("Databricks-Ai-Gateway-Request-Tags")).toBe('{"user_id":"real@example.com"}');
    expect(JSON.parse(String(transport.mock.calls[0]![1]?.body))).toMatchObject({ model: "dahlia.ai.gpt-5-6-luna" });
  });

  it("rejects full model paths and missing OBO before sending", async () => {
    const transport = vi.fn<GatewayFetch>();
    const service = new GatewayService(databricksConfig, transport);
    for (const model of ["other.ai.model", "dahlia.ai.model", "../model"]) {
      await expect(service.responses(request({ model, input: [] }), identity)).rejects.toMatchObject({ code: "invalid_model" });
    }
    await expect(service.responses(request({ model: "model", input: [] }), identity)).rejects.toMatchObject({ status: 401 });
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
    for (const body of [
      { model: "model", input: [], max_output_tokens: null },
      { model: "model", input: [], stream: null },
      { model: "model", prompt: { id: "pmpt_example" } },
    ]) {
      await service.responses(request(body, { "x-forwarded-access-token": "obo" }), identity);
      expect(JSON.parse(String(transport.mock.calls.at(-1)![1]?.body))).toEqual({
        ...body, model: backendConfig.provider?.backend === "databricks" ? "dahlia.ai.model" : "model",
      });
    }
  });

  it("rejects invalid input, compression, and excessive bytes without calling upstream", async () => {
    const transport = vi.fn<GatewayFetch>();
    const service = new GatewayService(config, transport);
    for (const body of [{ input: [] }, { model: "model", input: 1 }, { model: "model", input: [null] }, { model: "model", input: [], stream: "true" }, { model: "model", input: [], max_output_tokens: -1 }]) {
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

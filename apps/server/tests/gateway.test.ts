import { describe, expect, it, vi } from "vitest";

import type { ModelAliasRecord } from "../src/auth/store";
import type { AppConfig } from "../src/config";
import { GatewayService, LATEST_CODEX_CLIENT_VERSION } from "../src/ai-gateway/service";

const alias: ModelAliasRecord = {
  alias: "summary",
  upstreamModel: "provider/model-v2",
  displayName: "Summary",
  enabled: true,
  createdAt: new Date("2026-08-13T00:00:00Z"),
  updatedAt: new Date("2026-08-13T00:00:00Z"),
};
const registry = {
  listModelAliases: () => Promise.resolve([alias]),
  getEnabledModelAlias: (model: string) => Promise.resolve(model === alias.alias ? alias : null),
};
const config: AppConfig = {
  authProvider: "header",
  authHeader: "X-Forwarded-Email",
  databaseType: "sqlite",
  baseUrl: "https://dahlia.example",
  provider: {
    backend: "openai",
    baseUrl: "https://upstream.example/v1",
    apiKey: "secret",
  },
  oauthRedirectUris: [],
  maxRequestBytes: 1024,
};
const databricksConfig: AppConfig = {
  ...config,
  provider: { backend: "databricks", baseUrl: "https://workspace.example/ai-gateway/mlflow/v1" },
  databricksWorkspace: {
    host: "https://workspace.example",
    clientId: "app-client-id",
    clientSecret: "app-client-secret",
    tokenUrl: "https://workspace.example/oidc/v1/token",
  },
};

describe("AI Gateway", () => {
  it("exposes enabled database aliases", async () => {
    const response = await new GatewayService(config, registry).models();
    expect(response).toMatchObject({
      object: "list",
      data: [{
        id: "summary",
        object: "model",
        created: 1_786_579_200,
        owned_by: "dahlia",
        display_name: "Summary",
      }],
    });
    expect(response.models.filter((model) => model.visibility === "list")).toEqual([
      expect.objectContaining({
        slug: "summary",
        display_name: "Summary",
        default_reasoning_level: "max",
        include_apps_usage_instructions: false,
        supported_reasoning_levels: [
          expect.objectContaining({ effort: "none" }),
          expect.objectContaining({ effort: "low" }),
          expect.objectContaining({ effort: "high" }),
          expect.objectContaining({ effort: "max" }),
        ],
        priority: 0,
      }),
    ]);
    expect(response.models.find((model) => model.slug === "gpt-5.6-sol")).toMatchObject({
      visibility: "hide",
      model_messages: { instructions_template: "" },
    });
  });

  it("uses known Codex metadata for Databricks model services", async () => {
    const knownAlias = {
      ...alias,
      alias: "chat",
      upstreamModel: "system.ai.gpt-5-6-luna",
      displayName: "Chat",
    };
    const response = await new GatewayService(config, {
      ...registry,
      listModelAliases: () => Promise.resolve([knownAlias]),
    }).models(new Request(`https://dahlia.example/api/v1/models?client_version=${LATEST_CODEX_CLIENT_VERSION}`));
    const model = response.models.find((entry) => entry.slug === "chat");

    expect(model).toMatchObject({
      display_name: "Chat",
      default_reasoning_level: "medium",
      input_modalities: ["text", "image"],
      priority: 0,
      visibility: "list",
    });
    expect(model?.supported_reasoning_levels.map((option) => option.effort))
      .toEqual(["low", "medium", "high", "xhigh", "max"]);
    expect(model).not.toHaveProperty("use_responses_lite");
    expect(model).not.toHaveProperty("tool_mode");
    expect(model).not.toHaveProperty("supports_search_tool");
    expect(model).not.toHaveProperty("service_tiers");
    expect(model).toMatchObject({ availability_nux: null, upgrade: null });
  });

  it("exposes and resolves the configured Codex automatic review alias", async () => {
    const storedAutoReview = {
      ...alias,
      alias: "codex-auto-review",
      upstreamModel: "stale/model",
      displayName: "Stale Review",
    };
    const lookup = vi.fn(() => Promise.resolve(storedAutoReview));
    const transport = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer user-token");
      expect(JSON.parse(String(init?.body))).toMatchObject({ model: "system.ai.gpt-5-6-luna" });
      return new Response("{}");
    });
    const service = new GatewayService({
      ...databricksConfig,
      codexAutoReviewModel: "system.ai.gpt-5-6-luna",
    }, {
      listModelAliases: () => Promise.resolve([alias, storedAutoReview]),
      getEnabledModelAlias: lookup,
    }, transport);

    const listed = await service.models();
    expect(listed.data.filter((model) => model.id === "codex-auto-review")).toEqual([{
      id: "codex-auto-review",
      object: "model",
      created: 0,
      owned_by: "dahlia",
      display_name: "Codex Auto Review",
    }]);
    expect(listed.models.find((model) => model.slug === "codex-auto-review")).toMatchObject({
      display_name: "Codex Auto Review",
      default_reasoning_level: "medium",
      visibility: "list",
    });

    await service.responses(new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      headers: { "x-forwarded-access-token": "user-token" },
      body: JSON.stringify({ model: "codex-auto-review" }),
    }));
    expect(lookup).not.toHaveBeenCalled();
    expect(transport).toHaveBeenCalledOnce();

    const disabledService = new GatewayService(databricksConfig, {
      listModelAliases: () => Promise.resolve([storedAutoReview]),
      getEnabledModelAlias: lookup,
    }, transport);
    await expect(disabledService.responses(new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      headers: { "x-forwarded-access-token": "user-token" },
      body: JSON.stringify({ model: "codex-auto-review" }),
    }))).rejects.toMatchObject({ status: 404, code: "model_not_found" });
    expect(lookup).not.toHaveBeenCalled();
    expect(transport).toHaveBeenCalledOnce();
  });

  it("uses the OSS reasoning default for Databricks models without bundled metadata", async () => {
    const response = await new GatewayService(config, {
      ...registry,
      listModelAliases: () => Promise.resolve([
        { ...alias, alias: "kimi", upstreamModel: "system.ai.kimi-k3" },
        { ...alias, alias: "deepseek", upstreamModel: "system.ai.deepseek-v4-pro-0813" },
      ]),
    }).models();

    for (const slug of ["kimi", "deepseek"]) {
      const model = response.models.find((entry) => entry.slug === slug);
      expect(model?.default_reasoning_level).toBe("max");
      expect(model?.supported_reasoning_levels.map((option) => option.effort))
        .toEqual(["none", "low", "high", "max"]);
    }
  });

  it("does not expose canonical upgrade targets through aliases", async () => {
    const response = await new GatewayService(config, {
      ...registry,
      listModelAliases: () => Promise.resolve([{
        ...alias,
        alias: "legacy-chat",
        upstreamModel: "system.ai.gpt-5-4",
      }]),
    }).models();

    expect(response.models.find((entry) => entry.slug === "legacy-chat"))
      .toMatchObject({ availability_nux: null, upgrade: null });
  });

  it("rejects unsupported explicit Codex client versions", async () => {
    const service = new GatewayService(config, registry);

    await expect(service.models(new Request(
      "https://dahlia.example/api/v1/models?client_version=0.150.0",
    ))).rejects.toMatchObject({ status: 400, code: "unsupported_codex_client_version" });
  });

  it("keeps stored aliases in the non-Databricks administration list", async () => {
    expect(await new GatewayService(config, registry).adminModels(new Request("https://dahlia.example")))
      .toEqual([{ ...alias, configured: true }]);
  });

  it("merges Databricks models with stored aliases and hides missing aliases", async () => {
    const configured = { ...alias, alias: "gpt-5-6-luna", upstreamModel: "system.ai.gpt-5-6-luna" };
    const transport = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).endsWith("/oidc/v1/token")) {
        expect(new Headers(init?.headers).get("authorization")).toBe("Basic YXBwLWNsaWVudC1pZDphcHAtY2xpZW50LXNlY3JldA==");
        return Response.json({ access_token: "app-token", expires_in: 3600 });
      }
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer app-token");
      const pageToken = new URL(String(input)).searchParams.get("page_token");
      return pageToken
        ? Response.json({ model_services: [{
            name: "model-services/system.ai.long-name",
            update_time: "2026-08-04T00:00:00Z",
          }] })
        : Response.json({
            model_services: [
              { name: "model-services/system.ai.gpt-5-6-luna", update_time: "2026-08-01T00:00:00Z" },
              { name: "model-services/system.ai.gpt-5-6-sol", update_time: "2026-08-02T00:00:00Z" },
              { name: "model-services/system.ai.summary", update_time: "2026-08-03T00:00:00Z" },
            ],
            next_page_token: "next-page",
          });
    });
    const service = new GatewayService(databricksConfig, {
      ...registry,
      listModelAliases: () => Promise.resolve([configured, alias]),
    }, transport);

    expect(await service.adminModels(new Request("https://dahlia.example/api/admin/models", {
      headers: { "x-forwarded-access-token": "user-token" },
    }))).toEqual([
      { ...configured, updateTime: "2026-08-01T00:00:00Z", configured: true },
      {
        alias: "gpt-5-6-sol",
        upstreamModel: "system.ai.gpt-5-6-sol",
        displayName: null,
        updateTime: "2026-08-02T00:00:00Z",
        enabled: false,
        configured: false,
      },
      {
        alias: "summary-2",
        upstreamModel: "system.ai.summary",
        displayName: null,
        updateTime: "2026-08-03T00:00:00Z",
        enabled: false,
        configured: false,
      },
      {
        alias: "long-name",
        upstreamModel: "system.ai.long-name",
        displayName: null,
        updateTime: "2026-08-04T00:00:00Z",
        enabled: false,
        configured: false,
      },
    ]);
    expect(transport).toHaveBeenCalledTimes(3);
  });

  it("bounds Databricks model discovery", async () => {
    const deadline = AbortSignal.abort(new Error("timeout"));
    const tokenTimeout = new AbortController().signal;
    const timeout = vi.spyOn(AbortSignal, "timeout")
      .mockReturnValueOnce(deadline)
      .mockReturnValueOnce(tokenTimeout);
    const transport = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).endsWith("/oidc/v1/token")) {
        return Response.json({ access_token: "app-token", expires_in: 3600 });
      }
      expect(init?.signal?.aborted).toBe(true);
      return Response.json({ model_services: [] });
    });
    const service = new GatewayService(databricksConfig, registry, transport);

    await service.adminModels(new Request("https://dahlia.example/api/admin/models"));

    expect(timeout).toHaveBeenCalledWith(30_000);
    expect(timeout.mock.calls).toHaveLength(2);
    timeout.mockRestore();
  });

  it("rejects unavailable or invalid Databricks model lists", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const request = () => new Request("https://dahlia.example/api/admin/models");
    const modelTransport = (response: () => Response) => vi.fn(async (input: RequestInfo | URL) => {
      if (String(input).endsWith("/oidc/v1/token")) {
        return Response.json({ access_token: "app-token", expires_in: 3600 });
      }
      return response();
    });

    await expect(new GatewayService(databricksConfig, registry, modelTransport(() => new Response(JSON.stringify({
      error: "private",
    }), {
      status: 503,
      headers: { "x-databricks-request-id": "request-123" },
    })))
      .adminModels(request())).rejects.toMatchObject({ status: 502, code: "provider_models_unavailable" });
    const loggedError = String(consoleError.mock.calls.at(-1)?.[0]);
    expect(JSON.parse(loggedError)).toEqual({
      level: "error",
      event: "databricks_model_list_failed",
      reason: "upstream_http_error",
      status: 503,
      requestId: "request-123",
    });
    expect(loggedError).not.toContain("private");
    expect(loggedError).not.toContain("user-token");
    await expect(new GatewayService(databricksConfig, registry, modelTransport(() => Response.json({
      model_services: [{}],
    })))
      .adminModels(request())).rejects.toMatchObject({ status: 502, code: "provider_models_invalid" });
    await expect(new GatewayService(databricksConfig, registry, modelTransport(() => Response.json({
      model_services: [{ name: "model-services/catalog.schema.model" }],
    }))).adminModels(request())).rejects.toMatchObject({ status: 502, code: "provider_models_invalid" });
    await expect(new GatewayService(databricksConfig, registry, modelTransport(() => Response.json({
      model_services: [],
      next_page_token: "same-page",
    }))).adminModels(request())).rejects.toMatchObject({ status: 502, code: "provider_models_invalid" });
    await expect(new GatewayService(databricksConfig, registry, async () => new Response("private", { status: 503 }))
      .adminModels(new Request("https://dahlia.example")))
      .rejects.toMatchObject({ status: 502, code: "provider_models_unavailable" });
    expect(String(consoleError.mock.calls.at(-1)?.[0])).not.toContain("private");
    consoleError.mockRestore();
  });

  it("rewrites only the model and streams the upstream body", async () => {
    let sentBody = "";
    const transport = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      sentBody = String(init?.body);
      return new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode("data: first\n\n"));
          controller.enqueue(new TextEncoder().encode("data: second\n\n"));
          controller.close();
        },
      }), { headers: { "content-type": "text/event-stream" } });
    });
    const service = new GatewayService(config, registry, transport);

    const response = await service.responses(new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: "summary", stream: true, tools: [{ type: "function", name: "note" }] }),
    }));

    expect(JSON.parse(sentBody)).toEqual({
      model: "provider/model-v2",
      stream: true,
      tools: [{ type: "function", name: "note" }],
    });
    expect(response.body).toBeInstanceOf(ReadableStream);
    expect(await response.text()).toBe("data: first\n\ndata: second\n\n");
    expect(response.headers.get("x-accel-buffering")).toBe("no");
  });

  it("disables upstream payload logging independently of the database backend", async () => {
    const transport = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(new Headers(init?.headers).get("cf-aig-collect-log-payload")).toBe("false");
      return new Response("{}");
    });
    const service = new GatewayService({
      ...config,
      provider: { backend: "cloudflare", baseUrl: "https://upstream.example/v1", apiKey: "secret" },
    }, registry, transport);

    await service.responses(new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      body: JSON.stringify({ model: "summary" }),
    }));
    expect(transport).toHaveBeenCalledOnce();
  });

  it("uses the forwarded Databricks access token", async () => {
    const transport = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      expect(String(input)).toBe("https://workspace.example/ai-gateway/mlflow/v1/responses");
      const headers = new Headers(init?.headers);
      expect(headers.get("authorization")).toBe("Bearer user-token");
      expect(headers.has("x-forwarded-access-token")).toBe(false);
      return new Response("{}");
    });
    const service = new GatewayService(databricksConfig, registry, transport);
    const request = new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      headers: { "x-forwarded-access-token": "user-token" },
      body: JSON.stringify({ model: "summary" }),
    });

    await service.responses(request);
    expect(transport).toHaveBeenCalledOnce();
  });

  it("requires the forwarded Databricks access token", async () => {
    const transport = vi.fn();
    const service = new GatewayService(databricksConfig, registry, transport);

    await expect(service.responses(new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      body: JSON.stringify({ model: "summary" }),
    }))).rejects.toMatchObject({ status: 401, code: "databricks_access_token_required" });
    expect(transport).not.toHaveBeenCalled();
  });

  it("rejects Codex request compression with an actionable error", async () => {
    const service = new GatewayService(config, registry);
    const request = new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      headers: { "content-encoding": "zstd" },
      body: "compressed",
    });

    await expect(service.responses(request)).rejects.toMatchObject({
      status: 415,
      code: "unsupported_content_encoding",
    });
  });

  it("rejects unknown or disabled aliases before calling upstream", async () => {
    const transport = vi.fn();
    const service = new GatewayService(config, registry, transport);
    const request = new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      body: JSON.stringify({ model: "other" }),
    });

    await expect(service.responses(request)).rejects.toMatchObject({ status: 404, code: "model_not_found" });
    expect(transport).not.toHaveBeenCalled();
  });

  it("reports an unconfigured provider without exposing models", async () => {
    const service = new GatewayService({ ...config, provider: undefined }, registry);
    expect((await service.models()).data).toEqual([]);
    const request = new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      body: JSON.stringify({ model: "summary" }),
    });

    await expect(service.responses(request)).rejects.toMatchObject({
      status: 503,
      code: "provider_not_configured",
    });
  });

  it("fails closed when the model registry is unavailable", async () => {
    const unavailable = {
      listModelAliases: () => Promise.reject(new Error("database unavailable")),
      getEnabledModelAlias: () => Promise.reject(new Error("database unavailable")),
    };
    const service = new GatewayService(config, unavailable);
    await expect(service.models()).rejects.toMatchObject({ status: 503, code: "model_registry_unavailable" });
    await expect(service.responses(new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      body: JSON.stringify({ model: "summary" }),
    }))).rejects.toMatchObject({ status: 503, code: "model_registry_unavailable" });
  });

  it("stops reading a body once the byte limit is crossed", async () => {
    const service = new GatewayService(config, registry);
    const request = new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      body: "x".repeat(config.maxRequestBytes + 1),
    });

    await expect(service.responses(request)).rejects.toMatchObject({ status: 413, code: "request_too_large" });
  });

  it("preserves upstream status, error body, and retry metadata", async () => {
    const service = new GatewayService(
      config,
      registry,
      async () => new Response('{"error":{"message":"rate limited"}}', {
        status: 429,
        headers: { "content-type": "application/json", "retry-after": "3" },
      }),
    );
    const response = await service.responses(new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      body: JSON.stringify({ model: "summary" }),
    }));

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("3");
    expect(await response.json()).toEqual({ error: { message: "rate limited" } });
  });
});

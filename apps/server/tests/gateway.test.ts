import { describe, expect, it, vi } from "vitest";

import type { ModelAliasRecord } from "../src/auth/store";
import type { AppConfig } from "../src/config";
import { GatewayService } from "../src/ai-gateway/service";

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
    expect(await new GatewayService(config, registry).models()).toEqual({
      object: "list",
      data: [{
        id: "summary",
        object: "model",
        created: 1_786_579_200,
        owned_by: "dahlia",
        display_name: "Summary",
      }],
    });
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
        ? Response.json({ model_services: [{ name: "model-services/system.ai.long-name" }] })
        : Response.json({
            model_services: [
              { name: "model-services/system.ai.gpt-5-6-luna" },
              { name: "model-services/system.ai.gpt-5-6-sol" },
              { name: "model-services/system.ai.summary" },
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
      { ...configured, configured: true },
      {
        alias: "gpt-5-6-sol",
        upstreamModel: "system.ai.gpt-5-6-sol",
        displayName: null,
        enabled: false,
        configured: false,
      },
      {
        alias: "summary-2",
        upstreamModel: "system.ai.summary",
        displayName: null,
        enabled: false,
        configured: false,
      },
      {
        alias: "long-name",
        upstreamModel: "system.ai.long-name",
        displayName: null,
        enabled: false,
        configured: false,
      },
    ]);
    expect(transport).toHaveBeenCalledTimes(3);
  });

  it("bounds Databricks model discovery", async () => {
    const timeoutSignal = AbortSignal.abort(new Error("timeout"));
    const timeout = vi.spyOn(AbortSignal, "timeout").mockReturnValue(timeoutSignal);
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

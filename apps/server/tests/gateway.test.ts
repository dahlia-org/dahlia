import { describe, expect, it, vi } from "vitest";

import type { ModelAliasRecord } from "../src/auth/store";
import type { AppConfig } from "../src/config";
import { GatewayService } from "../src/gateway/service";

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

  it("uses and caches a Databricks service principal OAuth token", async () => {
    const transport = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).endsWith("/oidc/v1/token")) {
        expect(init?.method).toBe("POST");
        expect(new Headers(init?.headers).get("authorization")).toMatch(/^Basic /);
        return Response.json({ access_token: "workspace-token", expires_in: 3600 });
      }
      expect(String(input)).toBe("https://workspace.example/ai-gateway/openai/v1/responses");
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer workspace-token");
      return new Response("{}");
    });
    const service = new GatewayService({
      ...config,
      provider: {
        backend: "databricks",
        baseUrl: "https://workspace.example/ai-gateway/openai/v1",
        clientId: "app-client-id",
        clientSecret: "app-client-secret",
        tokenUrl: "https://workspace.example/oidc/v1/token",
      },
    }, registry, transport);
    const request = () => new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      body: JSON.stringify({ model: "summary" }),
    });

    await service.responses(request());
    await service.responses(request());

    expect(transport.mock.calls.filter(([input]) => String(input).endsWith("/oidc/v1/token"))).toHaveLength(1);
  });

  it("bounds Databricks service principal OAuth token acquisition", async () => {
    const timeoutSignal = AbortSignal.abort(new Error("timeout"));
    const timeout = vi.spyOn(AbortSignal, "timeout").mockReturnValue(timeoutSignal);
    const transport = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      expect(init?.signal).toBe(timeoutSignal);
      throw timeoutSignal.reason;
    });
    const service = new GatewayService({
      ...config,
      provider: {
        backend: "databricks",
        baseUrl: "https://workspace.example/ai-gateway/openai/v1",
        clientId: "app-client-id",
        clientSecret: "app-client-secret",
        tokenUrl: "https://workspace.example/oidc/v1/token",
      },
    }, registry, transport);

    await expect(service.responses(new Request("https://dahlia.example/api/v1/responses", {
      method: "POST",
      body: JSON.stringify({ model: "summary" }),
    }))).rejects.toMatchObject({ status: 502, code: "provider_authentication_failed" });
    expect(timeout).toHaveBeenCalledWith(30_000);
    timeout.mockRestore();
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

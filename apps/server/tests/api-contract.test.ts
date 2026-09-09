import { describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { createWorkerHandler } from "../src/worker";
import { testStore } from "./test-store";

const config = {
  authProvider: "header" as const, authHeader: "X-Forwarded-Email", databaseType: "sqlite" as const,
  baseUrl: "https://dahlia.example", oauthRedirectUris: [], maxRequestBytes: 1024,
};
const identityHeaders = { "x-forwarded-email": "owner@example.com", "x-forwarded-user": "owner" };

describe.each(["node", "worker"])("v1 HTTP contract (%s)", (runtime) => {
  function fixture() {
    const app = createApp({ config, authStore: testStore(), extensions: [{
      registerRoutes(app) {
        app.post("/api/v1/custom", (context) => context.json({ extension: true }));
        app.post("/api/v1/vaults/custom", (context) => context.json({ userId: context.get("identity")?.userId }));
        app.post("/api/v1/capabilities", (context) => context.json({ extension: true }));
        app.post("/api/v1/custom/:id", (context) => context.json({ extension: true }));
        app.post("/api/v1/vaults/hooked", (context) => context.json({ extension: true }));
        app.all("/api/v1/vaults/custom-fallback", (context) => context.json({ extensionFallback: true }, 418));
      },
      beforeGateway: async ({ path, method }) => path === "/api/v1/vaults/hooked" && method === "DELETE"
        ? Response.json({ error: "extension_denied" }, { status: 429 }) : undefined,
    }] });
    const worker = createWorkerHandler(async () => app);
    const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    return (path: string, method = "GET", body?: string, headers = identityHeaders as Record<string, string>) => {
      const request = new Request(`${config.baseUrl}${path}`, { method, body, headers });
      return runtime === "node" ? app.request(request) : fetchWorker(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
  }

  it("distinguishes unsupported methods, missing paths, disabled features and extensions", async () => {
    const send = fixture();
    for (const path of ["/api/v1/files/id/metadata", "/api/v1/capabilities", "/api/v1/transactions"]) {
      const response = await send(path, "DELETE");
      expect(response.status).toBe(405);
      expect(response.headers.get("allow")).toBe(path.endsWith("/metadata") ? "PATCH, GET, HEAD"
        : path.endsWith("/transactions") ? "POST" : "GET, HEAD, POST");
    }
    expect((await send("/api/v1/files/id/metadata", "PUT", undefined, {})).status).toBe(401);
    expect((await send("/api/v1/missing")).status).toBe(404);
    expect((await send("/api/auth/sign-in/google", "PATCH")).status).toBe(404);
    const permissions = await send("/api/v1/vaults/id/permissions", "POST");
    expect(permissions.status).toBe(405);
    expect(permissions.headers.get("allow")).toBe("GET, HEAD");
    expect((await send("/api/sessions", "POST", undefined, { ...identityHeaders, origin: config.baseUrl })).status).toBe(404);
    expect(await (await send("/api/v1/custom", "POST")).json()).toEqual({ extension: true });
    expect(await (await send("/api/v1/vaults/custom", "POST")).json()).toEqual({ userId: "owner" });
    expect((await send("/api/v1/vaults/custom", "POST", undefined, {})).status).toBe(401);
    const mcp = await send("/mcp", "DELETE");
    expect(mcp.status).toBe(405);
    expect(mcp.headers.get("allow")).toBe("POST");
  });

  it("merges extension methods across overlapping paths and preserves extension fallbacks", async () => {
    const send = fixture();
    for (const [path, allowed] of [
      ["/api/v1/custom", ["POST"]],
      ["/api/v1/custom/item", ["POST"]],
      ["/api/v1/vaults/custom", ["GET", "HEAD", "POST"]],
      ["/api/v1/capabilities", ["GET", "HEAD", "POST"]],
    ] as const) {
      const response = await send(path, "DELETE");
      expect(response.status).toBe(405);
      expect(new Set(response.headers.get("allow")?.split(", "))).toEqual(new Set(allowed));
      expect((await send(path, "DELETE", undefined, {})).status).toBe(401);
    }
    expect((await send("/api/v1/vaults/hooked", "DELETE")).status).toBe(429);
    const custom = await send("/api/v1/vaults/custom-fallback", "DELETE");
    expect(custom.status).toBe(418);
    expect(await custom.json()).toEqual({ extensionFallback: true });
    expect((await send("/api/v1/unknown", "DELETE")).status).toBe(404);
  });

  it("removes Artifact routes and exposes only read-only MCP tools", async () => {
    const send = fixture();
    for (const path of ["/api/v1/artifacts", "/api/v1/artifacts/id", "/api/v1/artifacts/id/content"]) {
      for (const method of ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]) {
        expect((await send(path, method)).status).toBe(404);
      }
    }
    const mcp = (method: string, params: Record<string, unknown>) => {
      const body = JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: {
        ...params, _meta: { "io.modelcontextprotocol/clientCapabilities": {},
          "io.modelcontextprotocol/clientInfo": { name: "API test", version: "1" },
          "io.modelcontextprotocol/protocolVersion": "2026-07-28" },
      } });
      return send("/mcp", "POST", body, { ...identityHeaders, "content-type": "application/json",
        "content-length": String(new TextEncoder().encode(body).length), "mcp-method": method,
        "mcp-name": String(params.name ?? ""), "mcp-protocol-version": "2026-07-28" });
    };
    const listed = await mcp("tools/list", {});
    expect(listed.status).toBe(200);
    const { result }: { result: { tools: Array<{ name: string; annotations: { readOnlyHint: boolean } }> } } = await listed.json();
    expect(result.tools.map((tool) => tool.name).sort()).toEqual([
      "get_meeting", "get_meeting_screenshots", "get_meeting_transcript", "get_project",
      "query_meetings", "query_projects", "query_screenshots", "search",
    ]);
    expect(result.tools.every((tool) => tool.annotations.readOnlyHint)).toBe(true);
    for (const name of ["create_artifact", "update_artifact_content", "update_artifact_visibility", "delete_artifact"]) {
      expect(await (await mcp("tools/call", { name, arguments: {} })).json()).toHaveProperty("error");
    }
  });
});

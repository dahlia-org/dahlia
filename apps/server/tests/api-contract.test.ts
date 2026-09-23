import type { ChatMemoryService } from "../src/agent/context-service";
import { testUserID } from "./public-test-client";
import { describe, expect, it } from "vitest";
import { createApp } from "./public-test-client";
import { createWorkerHandler } from "../src/worker";
import { testStore } from "./test-store";
import type { AiService } from "../src/agent/service";
import type { AiHistoryCursor, AiHistoryService, AiThread } from "../src/agent/history";
import { encodeId } from "../src/typeid";
import { MeetingSyncService } from "../src/sync/service";

const config = {
  authProvider: "header" as const, authHeader: "X-Forwarded-Email", databaseType: "sqlite" as const,
  baseUrl: "https://dahlia.example", oauthRedirectUris: [], maxRequestBytes: 1024,
};
const identityHeaders = { "x-forwarded-email": "owner@example.com", "x-forwarded-user": "owner" };

describe.each(["node", "worker"])("v1 HTTP contract (%s)", (runtime) => {
  const aiService: AiService = {
    models: async () => ["test-model", "error-model"].map((id) => ({
      id, displayName: id === "test-model" ? "Test model" : "Error model", defaultReasoningEffort: "medium" as const,
      supportedReasoningEfforts: [{ effort: "low" as const, description: "Fast" }, { effort: "medium" as const, description: "Balanced" }],
    })),
    async *stream(input) {
      if (input.model === "error-model") {
        yield { type: "text", text: "Partial" };
        throw new Error("secret tool output");
      }
      yield { type: "tool", name: "query_meetings", status: "running" };
      yield { type: "tool", name: "query_meetings", status: "complete" };
      yield { type: "text", text: "Answer" };
    },
  };
  function fixture(withAi = false, selectedAiService = aiService, aiHistory?: AiHistoryService,
    workspaceEncryption?: "none" | "server", chatMemory?: ChatMemoryService) {
    const store = testStore();
    if (withAi) store.sync.isAvailable = async () => true;
    const syncService = withAi ? {
      parseId: (value: string) => MeetingSyncService.prototype.parseId.call(undefined, value),
      getWorkspace: async (_identity: unknown, requestedWorkspaceId: string) => requestedWorkspaceId === "01990ab0-0000-7000-8000-000000000001"
        ? { workspaceId: requestedWorkspaceId, encryption: workspaceEncryption } : null,
    } as unknown as MeetingSyncService : undefined;
    const app = createApp({ config, authStore: store, aiService: withAi ? selectedAiService : undefined, aiHistory, syncService, chatMemory, extensions: [{
      registerRoutes(app) {
        app.post("/api/v1/custom", (context) => context.json({ extension: true }));
        app.post("/api/v1/workspaces/custom", (context) => context.json({ userId: context.get("identity")?.userId }));
        app.post("/api/v1/capabilities", (context) => context.json({ extension: true }));
        app.post("/api/v1/custom/:id", (context) => context.json({ extension: true }));
        app.post("/api/v1/workspaces/hooked", (context) => context.json({ extension: true }));
        app.all("/api/v1/workspaces/custom-fallback", (context) => context.json({ extensionFallback: true }, 418));
      },
      beforeGateway: async ({ path, method }) => path === "/api/v1/workspaces/hooked" && method === "DELETE"
        ? Response.json({ error: "extension_denied" }, { status: 429 }) : undefined,
    }] });
    const worker = createWorkerHandler(async () => app);
    const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
    return (path: string, method = "GET", body?: string, headers = identityHeaders as Record<string, string>) => {
      const request = new Request(`${config.baseUrl}${path}`, { method, body, headers });
      return runtime === "node" ? app.request(request) : fetchWorker(request, {} as Cloudflare.Env, {} as ExecutionContext);
    };
  }

  it("routes private Working Memory and live meeting selection through authenticated, validated contracts", async () => {
    const settings = { revision: 0, automatic: true, capacityReached: false, manual: "", learned: "" };
    let selected: string | null = null;
    const service = { store: { settings: async () => settings, editSettings: async (_identity: unknown, input: typeof settings) => input },
      select: async (_identity: unknown, _threadId: string, meetingId: string | null) => { selected = meetingId; },
      context: async () => ({ status: { meetingId: selected, status: selected ? "pending" : "off", processedThrough: null, updatedAt: null }, context: "" }),
    } as unknown as ChatMemoryService;
    const send = fixture(true, aiService, undefined, "none", service);
    expect((await send("/api/v1/user/memory/working", "GET", undefined, {})).status).toBe(401);
    expect(await (await send("/api/v1/user/memory/working")).json()).toEqual(settings);
    const headers = { ...identityHeaders, origin: config.baseUrl, "content-type": "application/json" };
    expect((await send("/api/v1/user/memory/working", "PATCH", JSON.stringify({ section: "manual", content: "x".repeat(6001), revision: 0, explicit: true }), headers)).status).toBe(400);
    expect((await send("/api/v1/user/memory/working", "PATCH", JSON.stringify({ section: "manual", content: "note", revision: 0, explicit: true }), { ...headers, origin: "https://untrusted.example" })).status).toBe(403);
    const threadId = "01990ab0-0000-7000-8000-000000000010", meetingId = "01990ab0-0000-7000-8000-000000000011";
    expect((await send(`/api/v1/chat/${threadId}/live-context`, "PUT", JSON.stringify({ meetingId }), headers)).status).toBe(204);
    expect(selected).toBe(meetingId);
    expect(await (await send(`/api/v1/chat/${threadId}/live-context`)).json()).toMatchObject({ meetingId, status: "pending" });
    expect((await send(`/api/v1/chat/${threadId}/live-context`, "PUT", JSON.stringify({ meetingId: null }), headers)).status).toBe(204);
    expect(selected).toBeNull();
  });

  it("gates AI in the session and streams sanitized Agent events", async () => {
    const send = fixture(true);
    const session: { capabilities: Record<string, boolean> } = await (await send("/api/v1/session")).json();
    expect(session.capabilities.ai).toBe(true);
    expect(await (await send("/api/v1/chat/models")).json()).toEqual({ items: [
      { id: "test-model", displayName: "Test model", defaultReasoningEffort: "medium", supportedReasoningEfforts: [
        { effort: "low", description: "Fast" }, { effort: "medium", description: "Balanced" },
      ] },
      { id: "error-model", displayName: "Error model", defaultReasoningEffort: "medium", supportedReasoningEfforts: [
        { effort: "low", description: "Fast" }, { effort: "medium", description: "Balanced" },
      ] },
    ] });
    expect((await send("/api/v1/chat/models", "GET", undefined, {})).status).toBe(401);
    const workspaceId = encodeId("workspace", "01990ab0-0000-7000-8000-000000000001");
    const body = JSON.stringify({ workspaceId, model: "test-model", reasoningEffort: "medium", messages: [{ role: "user", content: "Question" }] });
    const response = await send("/api/v1/chat/messages", "POST", body, { ...identityHeaders, origin: config.baseUrl, "content-type": "application/json" });
    expect(response.status).toBe(200);
    const events = await response.text();
    expect(events).toMatch(/event: tool[\s\S]+event: tool[\s\S]+event: text[\s\S]+event: done/);
    expect(events).not.toContain("workspaceId");
    const invalid = await send("/api/v1/chat/messages", "POST", JSON.stringify({ workspaceId, model: "test-model", reasoningEffort: "medium", messages: [
      { role: "user", content: "one" }, { role: "user", content: "two" },
    ] }), { ...identityHeaders, origin: config.baseUrl, "content-type": "application/json" });
    expect(invalid.status).toBe(400);

    const inaccessible = encodeId("workspace", "01990ab0-0000-7000-8000-000000000002");
    expect((await send("/api/v1/chat/messages", "POST", JSON.stringify({ workspaceId: inaccessible, model: "test-model", reasoningEffort: "medium", messages: [
      { role: "user", content: "Question" },
    ] }), { ...identityHeaders, origin: config.baseUrl, "content-type": "application/json" })).status).toBe(404);

    const tooLarge = await send("/api/v1/chat/messages", "POST", JSON.stringify({ workspaceId, model: "test-model", reasoningEffort: "medium", messages: [
      { role: "user", content: "x".repeat(128 * 1024) },
    ] }), { ...identityHeaders, origin: config.baseUrl, "content-type": "application/json" });
    expect(tooLarge.status).toBe(413);

    const failed = await send("/api/v1/chat/messages", "POST", JSON.stringify({ workspaceId, model: "error-model", reasoningEffort: "medium", messages: [
      { role: "user", content: "Question" },
    ] }), { ...identityHeaders, origin: config.baseUrl, "content-type": "application/json" });
    const failedEvents = await failed.text();
    expect(failedEvents).toMatch(/event: text[\s\S]+event: error[\s\S]+event: done/);
    expect(failedEvents).toContain("ai_generation_failed");
    expect(failedEvents).not.toContain("secret tool output");
  });

  it("does not publish AI capability without an Agent-compatible model", async () => {
    const send = fixture(true, { ...aiService, models: async () => [] });
    const session: { capabilities: Record<string, boolean> } = await (await send("/api/v1/session")).json();
    expect(session.capabilities.ai).toBe(false);
    expect(await (await send("/api/v1/chat/models")).json()).toEqual({ items: [] });
    const capabilities = await (await send("/api/v1/capabilities")).json();
    expect(capabilities).not.toHaveProperty("ai");
  });

  it("creates, resumes and deletes an owned persistent AI thread", async () => {
    const workspaceUuid = "01990ab0-0000-7000-8000-000000000001";
    const workspaceId = encodeId("workspace", workspaceUuid);
    const threadUuid = "01990ab0-0000-7000-8000-000000000010";
    const threadId = encodeId("aiThread", threadUuid);
    const thread: AiThread = { id: threadUuid, title: "Question", workspaceId: workspaceUuid,
      createdAt: "2026-09-19T00:00:00.000Z", updatedAt: "2026-09-19T00:00:00.000Z" };
    let busy = false;
    let requestedCursor: AiHistoryCursor | undefined;
    let continuedHistory: { workspaceId: string; resourceId?: string } | undefined;
    const history: AiHistoryService = {
      memory: () => ({} as never),
      create: async (_identity, requestedWorkspaceId) => {
        expect(requestedWorkspaceId).toBe(workspaceUuid);
        return thread;
      },
      list: async () => ({ items: [thread], hasMore: false }),
      get: async (_identity, requestedThreadId, cursor) => {
        requestedCursor = cursor;
        return requestedThreadId === threadUuid
          ? { thread, messages: [{ id: "message-1", role: "user", content: "Question", createdAt: thread.createdAt }], hasMore: false }
          : null;
      },
      delete: async () => busy ? "busy" : "deleted",
      startRun: async () => busy ? null : "run-1",
      finishRun: async () => undefined,
    };
    const continuingAiService: AiService = { ...aiService, async *stream(input) {
      continuedHistory = { workspaceId: input.workspaceId, resourceId: input.history?.resourceId };
      yield { type: "text", text: "Answer" };
    } };
    const send = fixture(true, continuingAiService, history);
    const mutationHeaders = { ...identityHeaders, origin: config.baseUrl, "content-type": "application/json" };
    const encrypted = fixture(true, aiService, history, "server");
    expect((await encrypted("/api/v1/chat", "POST", JSON.stringify({ workspaceId, title: "Private" }), mutationHeaders)).status).toBe(409);
    const created = await send("/api/v1/chat", "POST", JSON.stringify({ workspaceId, title: "Question" }), mutationHeaders);
    expect(created.status, await created.clone().text()).toBe(201);
    expect(created.headers.get("location")).toBe(`/api/v1/chat/${threadUuid}`);
    expect(await created.json()).toEqual(thread);
    expect(await (await send("/api/v1/chat")).json()).toEqual({ items: [thread], hasMore: false });
    expect((await send("/api/v1/chat/invalid")).status).toBe(400);
    expect((await send(`/api/v1/chat/${encodeId("aiThread", "01990ab0-0000-7000-8000-000000000099")}`)).status).toBe(404);
    expect((await send("/api/v1/chat?page=1000000")).status).toBe(400);
    expect((await send(`/api/v1/chat/${threadId}?before=${encodeURIComponent(thread.createdAt)}`)).status).toBe(400);
    expect((await send(`/api/v1/chat/${threadId}?${new URLSearchParams({
      before: thread.createdAt, beforeId: "message-1", beforeRole: "user",
    })}`)).status).toBe(200);
    expect(requestedCursor).toEqual({ createdAt: new Date(thread.createdAt), id: "message-1", role: "user" });
    const continued = await send(`/api/v1/chat/${threadId}/messages`, "POST",
      JSON.stringify({ model: "test-model", reasoningEffort: "medium", content: "Question" }), mutationHeaders);
    expect(continued.status).toBe(200);
    expect(await continued.text()).toMatch(/event: text[\s\S]+event: done/);
    expect(continuedHistory).toEqual({ workspaceId: workspaceUuid, resourceId: testUserID("owner@example.com") });
    busy = true;
    expect((await send(`/api/v1/chat/${threadId}/messages`, "POST",
      JSON.stringify({ model: "test-model", reasoningEffort: "medium", content: "Again" }), mutationHeaders)).status).toBe(409);
    expect((await send(`/api/v1/chat/${threadId}`, "DELETE", undefined,
      { ...identityHeaders, origin: config.baseUrl })).status).toBe(409);
    busy = false;
    expect((await send(`/api/v1/chat/${threadId}`, "DELETE", undefined,
      { ...identityHeaders, origin: config.baseUrl })).status).toBe(204);
  });

  it("does not register the retired AI chat endpoints", async () => {
    const send = fixture(true);
    for (const [path, method] of [
      ["/api/v1/ai/models", "GET"], ["/api/v1/ai/chat", "POST"],
      ["/api/v1/ai/threads", "GET"], ["/api/v1/ai/threads", "POST"],
      ["/api/v1/ai/threads/old", "GET"], ["/api/v1/ai/threads/old", "DELETE"],
      ["/api/v1/ai/threads/old/messages", "POST"],
    ]) {
      expect((await send(path!, method, undefined, { ...identityHeaders, origin: config.baseUrl })).status).toBe(404);
    }
  });

  it("distinguishes unsupported methods, missing paths, disabled features and extensions", async () => {
    const send = fixture();
    for (const path of ["/api/v1/files/id", "/api/v1/capabilities", "/api/v1/transactions"]) {
      const response = await send(path, "DELETE");
      expect(response.status).toBe(405);
      expect(response.headers.get("allow")).toBe(path.match(/\/files\/[^/]+$/) ? "PATCH, GET, HEAD"
        : path.endsWith("/transactions") ? "POST" : "GET, HEAD, POST");
    }
    expect((await send("/api/v1/files/id", "PUT", undefined, {})).status).toBe(401);
    expect((await send("/api/v1/missing")).status).toBe(404);
    expect((await send("/api/auth/sign-in/google", "PATCH")).status).toBe(404);
    const permissions = await send("/api/v1/workspaces/id/permissions", "POST");
    expect(permissions.status).toBe(405);
    expect(permissions.headers.get("allow")).toBe("GET, HEAD");
    expect((await send("/api/v1/sessions", "POST", undefined, { ...identityHeaders, origin: config.baseUrl })).status).toBe(404);
    expect(await (await send("/api/v1/custom", "POST")).json()).toEqual({ extension: true });
    expect(await (await send("/api/v1/workspaces/custom", "POST")).json()).toEqual({ userId: testUserID("owner@example.com") });
    expect((await send("/api/v1/workspaces/custom", "POST", undefined, {})).status).toBe(401);
    const mcp = await send("/mcp", "DELETE");
    expect(mcp.status).toBe(405);
    expect(mcp.headers.get("allow")).toBe("POST");
  });

  it("merges extension methods across overlapping paths and preserves extension fallbacks", async () => {
    const send = fixture();
    for (const [path, allowed] of [
      ["/api/v1/custom", ["POST"]],
      ["/api/v1/custom/item", ["POST"]],
      ["/api/v1/workspaces/custom", ["GET", "HEAD", "POST"]],
      ["/api/v1/capabilities", ["GET", "HEAD", "POST"]],
    ] as const) {
      const response = await send(path, "DELETE");
      expect(response.status).toBe(405);
      expect(new Set(response.headers.get("allow")?.split(", "))).toEqual(new Set(allowed));
      expect((await send(path, "DELETE", undefined, {})).status).toBe(401);
    }
    expect((await send("/api/v1/workspaces/hooked", "DELETE")).status).toBe(429);
    const custom = await send("/api/v1/workspaces/custom-fallback", "DELETE");
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

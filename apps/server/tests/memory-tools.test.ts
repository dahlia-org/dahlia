import { describe, expect, it, vi } from "vitest";
import { createMemoryTools } from "../src/memory/tools";
import { HindsightError } from "../src/memory/hindsight";
import type { WorkspaceMemoryService } from "../src/memory/service";
import { meetingRequestContext } from "../src/agent/tools";
import { createServerMcpHandler, registerMastraTool } from "../src/mcp";
import { RequestError } from "../src/storage/upload";
import { encodeId } from "@dahlia-ai/ui/model/typeid";
import type { AppConfig } from "../src/config";
import type { MeetingSyncService } from "../src/sync/service";
import { uuidV7 } from "@dahlia-ai/ui/model/id";

const identity = { userId: uuidV7(), source: "header" as const }, workspaceId = uuidV7();
const input = { workspace_id: encodeId("workspace", workspaceId), query: "Decisions" };
// Strict agent tools receive every property; MCP callers may omit the options.
const agentInput = { ...input, project_id: null, after: null, before: null, depth: null };
const signal = new AbortController().signal;
function fixture() {
  const search = vi.fn().mockResolvedValue({ sources: [], hypothesis: null, coverage: "ready" });
  const tools = createMemoryTools({ search } as unknown as WorkspaceMemoryService);
  return { search, tools };
}
describe("shared memory tools", () => {
  it("uses one tool for Mastra and MCP with invocation-scoped identity, Workspace and cancellation", async () => {
    const { search, tools } = fixture();
    for (const [name, tool] of Object.entries(tools)) {
      expect(tool.mcp?.annotations?.readOnlyHint).toBe(true);
      await tool.execute!(agentInput, { requestContext: meetingRequestContext(identity, workspaceId), abortSignal: signal } as never);
      expect(search).toHaveBeenLastCalledWith(identity, workspaceId, input.query, name.startsWith("reflect"), signal, {});
      await expect(tool.execute!({ ...agentInput, workspace_id: encodeId("workspace", uuidV7()) }, {
        requestContext: meetingRequestContext(identity, workspaceId), abortSignal: signal,
      } as never)).rejects.toMatchObject({ code: "workspace_scope_mismatch" });
      let handler!: (input: unknown, context: unknown) => Promise<unknown>;
      const authorize = vi.fn();
      registerMastraTool({ registerTool(_name: string, _options: unknown, callback: typeof handler) { handler = callback; } } as never,
        tool, identity, undefined, authorize);
      expect(await handler(input, { mcpReq: { signal } })).toMatchObject({ content: [{ type: "text" }] });
      expect(authorize).toHaveBeenCalledTimes(2);
      search.mockRejectedValueOnce(new RequestError(404, "workspace_not_found"));
      expect(await handler(input, { mcpReq: { signal } })).toMatchObject({ isError: true, content: [{ text: "workspace_not_found" }] });
      authorize.mockRejectedValueOnce(new RequestError(401, "token_expired"));
      const calls = search.mock.calls.length;
      expect(await handler(input, { mcpReq: { signal } })).toMatchObject({ isError: true });
      expect(search).toHaveBeenCalledTimes(calls);
    }
  });
  it("converts Project, period and depth options for Mastra and MCP callers", async () => {
    const { search, tools } = fixture();
    const projectId = uuidV7();
    const options = { project_id: encodeId("project", projectId), after: "2026-01-01T00:00:00+09:00", before: "2026-03-31T23:59:59Z", depth: "deep" as const };
    await tools.reflect_workspace_memory.execute!({ ...agentInput, ...options }, { requestContext: meetingRequestContext(identity, workspaceId), abortSignal: signal } as never);
    expect(search).toHaveBeenLastCalledWith(identity, workspaceId, input.query, true, signal,
      { projectId, after: options.after, before: options.before, depth: "deep" });
    let handler!: (input: unknown, context: unknown) => Promise<unknown>;
    registerMastraTool({ registerTool(_name: string, _options: unknown, callback: typeof handler) { handler = callback; } } as never,
      tools.recall_workspace_memory, identity);
    expect(await handler({ ...input, depth: "quick" }, { mcpReq: { signal } })).not.toHaveProperty("isError");
    expect(search).toHaveBeenLastCalledWith(identity, workspaceId, input.query, false, signal, { depth: "quick" });
    expect(tools.recall_workspace_memory.mcpInputSchema.safeParse({ ...input, after: "last week" }).success).toBe(false);
    expect(tools.recall_workspace_memory.mcpInputSchema.safeParse({ ...input, project_id: encodeId("meeting", projectId) }).success).toBe(false);
  });
  it("preserves unavailability and abort semantics", async () => {
    const { search, tools } = fixture();
    search.mockRejectedValueOnce(new HindsightError("memory_not_ready"));
    expect(await tools.recall_workspace_memory.execute!(agentInput, {
      requestContext: meetingRequestContext(identity), abortSignal: signal,
    } as never)).toMatchObject({ unavailable: true, code: "memory_not_ready" });
    const controller = new AbortController(); controller.abort();
    search.mockRejectedValueOnce(controller.signal.reason);
    await expect(tools.recall_workspace_memory.execute!(agentInput, {
      requestContext: meetingRequestContext(identity), abortSignal: controller.signal,
    } as never)).rejects.toThrow();
  });
  it("keeps unsupported encrypted memory nonfatal in Mastra and MCP", async () => {
    const { search, tools } = fixture();
    search.mockRejectedValue(new RequestError(409, "memory_encrypted_workspace_unsupported"));
    for (const tool of Object.values(tools)) {
      expect(await tool.execute!(agentInput, { requestContext: meetingRequestContext(identity), abortSignal: signal } as never))
        .toMatchObject({ unavailable: true, code: "memory_encrypted_workspace_unsupported" });
      let handler!: (input: unknown, context: unknown) => Promise<unknown>;
      registerMastraTool({ registerTool(_name: string, _options: unknown, callback: typeof handler) { handler = callback; } } as never, tool, identity);
      const result = await handler(input, { mcpReq: { signal } });
      expect(result).not.toHaveProperty("isError");
      expect(JSON.stringify(result)).toContain("memory_encrypted_workspace_unsupported");
    }
  });
  it("advertises memory only when configured and the dedicated memory scope is granted", async () => {
    const { tools } = fixture();
    const list = async (configured: boolean, scopes: string[]) => {
      const handler = createServerMcpHandler({} as AppConfig, {} as MeetingSyncService, undefined, undefined, configured ? tools : undefined);
      const body = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {
        _meta: { "io.modelcontextprotocol/clientCapabilities": {}, "io.modelcontextprotocol/clientInfo": { name: "test", version: "1" },
          "io.modelcontextprotocol/protocolVersion": "2026-07-28" },
      } });
      const response = await handler.fetch(new Request("https://test.invalid/mcp", { method: "POST", body,
        headers: { "content-type": "application/json", "content-length": String(new TextEncoder().encode(body).length),
          "mcp-method": "tools/list", "mcp-protocol-version": "2026-07-28" } }),
      { authInfo: { token: "", clientId: "test", scopes, extra: { identity } } });
      const value: { result?: { tools: Array<{ name: string }> }; error?: unknown } = await response.json();
      if (!scopes.length) { expect(value.error).toBeDefined(); return []; }
      return value.result!.tools.map((tool) => tool.name);
    };
    for (const scope of ["mcp", "mcp:read"]) expect(await list(true, [scope])).not.toContain("recall_workspace_memory");
    expect(await list(true, ["mcp:memory:read"])).toEqual(expect.arrayContaining(Object.keys(tools)));
    expect(await list(true, ["mcp:memory:write"])).toEqual(expect.arrayContaining(Object.keys(tools)));
    expect(await list(false, ["mcp:read"])).not.toContain("recall_workspace_memory");
    expect(await list(true, [])).not.toContain("recall_workspace_memory");
  });
});

import { describe, expect, it, vi } from "vitest";
import { createMemoryTools } from "../src/memory/tools";
import { HindsightError } from "../src/memory/hindsight";
import type { WorkspaceMemoryService } from "../src/memory/service";
import { meetingRequestContext } from "../src/agent/tools";
import { createServerMcpHandler, registerMastraTool } from "../src/mcp";
import { RequestError } from "../src/storage/upload";
import { encodeId } from "../src/typeid";
import type { AppConfig } from "../src/config";
import type { MeetingSyncService } from "../src/sync/service";
import { uuidV7 } from "../src/id";

const identity = { userId: uuidV7(), source: "header" as const }, workspaceId = uuidV7();
const input = { workspace_id: encodeId("workspace", workspaceId), query: "Decisions" };
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
      await tool.execute!(input, { requestContext: meetingRequestContext(identity, workspaceId), abortSignal: signal } as never);
      expect(search).toHaveBeenLastCalledWith(identity, workspaceId, input.query, name.startsWith("reflect"), signal);
      await expect(tool.execute!({ ...input, workspace_id: encodeId("workspace", uuidV7()) }, {
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
  it("preserves unavailability and abort semantics", async () => {
    const { search, tools } = fixture();
    search.mockRejectedValueOnce(new HindsightError("memory_not_ready"));
    expect(await tools.recall_workspace_memory.execute!(input, {
      requestContext: meetingRequestContext(identity), abortSignal: signal,
    } as never)).toMatchObject({ unavailable: true, code: "memory_not_ready" });
    const controller = new AbortController(); controller.abort();
    search.mockRejectedValueOnce(controller.signal.reason);
    await expect(tools.recall_workspace_memory.execute!(input, {
      requestContext: meetingRequestContext(identity), abortSignal: controller.signal,
    } as never)).rejects.toThrow();
  });
  it("keeps unsupported encrypted memory nonfatal in Mastra and MCP", async () => {
    const { search, tools } = fixture();
    search.mockRejectedValue(new RequestError(409, "memory_encrypted_workspace_unsupported"));
    for (const tool of Object.values(tools)) {
      expect(await tool.execute!(input, { requestContext: meetingRequestContext(identity), abortSignal: signal } as never))
        .toMatchObject({ unavailable: true, code: "memory_encrypted_workspace_unsupported" });
      let handler!: (input: unknown, context: unknown) => Promise<unknown>;
      registerMastraTool({ registerTool(_name: string, _options: unknown, callback: typeof handler) { handler = callback; } } as never, tool, identity);
      const result = await handler(input, { mcpReq: { signal } });
      expect(result).not.toHaveProperty("isError");
      expect(JSON.stringify(result)).toContain("memory_encrypted_workspace_unsupported");
    }
  });
  it("advertises memory only when configured and the MCP read scope is granted", async () => {
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
    expect(await list(true, ["mcp:read"])).toEqual(expect.arrayContaining(Object.keys(tools)));
    expect(await list(false, ["mcp:read"])).not.toContain("recall_workspace_memory");
    expect(await list(true, [])).not.toContain("recall_workspace_memory");
  });
});

import { describe, expect, it, vi } from "vitest";
import { createDahliaMemoryTools } from "../src/memory/dahlia-tools";
import type { DahliaMemory } from "../src/memory/dahlia";
import { meetingRequestContext } from "../src/agent/tools";
import { createServerMcpHandler, registerMastraTool } from "../src/mcp";
import { RequestError } from "../src/storage/upload";
import { encodeId } from "@dahlia-ai/ui/model/typeid";
import type { AppConfig } from "../src/config";
import type { MeetingSyncService } from "../src/sync/service";
import { uuidV7 } from "@dahlia-ai/ui/model/id";

const identity = { userId: uuidV7(), source: "header" as const }, workspaceId = uuidV7();
const input = { scope: "workspace", workspaceId: encodeId("workspace", workspaceId), query: "Decisions" };
const signal = new AbortController().signal;
function fixture() {
  const search = vi.fn().mockResolvedValue({ searchedScopes: [], results: [] });
  const memory = { search } as unknown as DahliaMemory;
  return { search, memory, tools: createDahliaMemoryTools(memory, false) };
}
describe("shared memory tools", () => {
  it("uses one tool for Mastra and MCP with invocation-scoped identity, Workspace and cancellation", async () => {
    const { search, tools } = fixture();
    const tool = tools.search_memories;
    expect(tool.mcp?.annotations?.readOnlyHint).toBe(true);
    await tool.execute!(input, { requestContext: meetingRequestContext(identity, workspaceId), abortSignal: signal } as never);
    expect(search).toHaveBeenLastCalledWith(identity, { ...input, scope: "workspace" }, signal);
    await expect(tool.execute!({ ...input, workspaceId: encodeId("workspace", uuidV7()) }, {
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
    const controller = new AbortController(); controller.abort();
    await expect(tool.execute!(input, { requestContext: meetingRequestContext(identity), abortSignal: controller.signal } as never)).rejects.toThrow();
  });
  it("keeps Dahlia Memory reads nonfatal in an encrypted Workspace while writes still fail", async () => {
    const unsupported = () => Promise.reject(new RequestError(409, "memory_encrypted_workspace_unsupported"));
    const tools = createDahliaMemoryTools({ search: unsupported, save: unsupported, list: unsupported } as unknown as DahliaMemory);
    const context = { requestContext: meetingRequestContext(identity, workspaceId), abortSignal: signal } as never;
    const reads = [[tools.search_memories, { scope: "all", query: "Decisions" }], [tools.list_memories, { scope: "workspace" }]] as const;
    for (const [read, args] of reads) {
      expect(await read.execute!(args as never, context)).toMatchObject({ unavailable: true, code: "memory_encrypted_workspace_unsupported" });
      let handler!: (input: unknown, context: unknown) => Promise<unknown>;
      registerMastraTool({ registerTool(_name: string, _options: unknown, callback: typeof handler) { handler = callback; } } as never, read, identity);
      expect(await handler({ ...args, workspaceId: encodeId("workspace", workspaceId) }, { mcpReq: { signal } })).not.toHaveProperty("isError");
    }
    if (!("save_memory" in tools)) throw new Error("writable tools expected");
    await expect(tools.save_memory.execute!({ scope: "personal", id: encodeId("sharedMemory", uuidV7()), content: "x", revision: 0 }, context))
      .rejects.toThrow("memory_encrypted_workspace_unsupported");
  });
  it("advertises memory only when configured and the dedicated memory scope is granted", async () => {
    const { memory } = fixture();
    const rpc = async (configured: boolean, scopes: string[], method: string) => {
      const handler = createServerMcpHandler({} as AppConfig, {} as MeetingSyncService, undefined, undefined, configured ? memory : undefined);
      const body = JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: {
        _meta: { "io.modelcontextprotocol/clientCapabilities": {}, "io.modelcontextprotocol/clientInfo": { name: "test", version: "1" },
          "io.modelcontextprotocol/protocolVersion": "2026-07-28" },
      } });
      const response = await handler.fetch(new Request("https://test.invalid/mcp", { method: "POST", body,
        headers: { "content-type": "application/json", "content-length": String(new TextEncoder().encode(body).length),
          "mcp-method": method, "mcp-protocol-version": "2026-07-28" } }),
      { authInfo: { token: "", clientId: "test", scopes, extra: { identity } } });
      const value: { result?: { tools?: Array<{ name: string }>; instructions?: string }; error?: unknown } = await response.json();
      return value;
    };
    // A server without any tool rejects tools/list.
    const list = async (configured: boolean, scopes: string[]) => (await rpc(configured, scopes, "tools/list")).result?.tools?.map((tool) => tool.name) ?? [];
    for (const scope of ["mcp", "mcp:read"]) expect(await list(true, [scope])).not.toContain("search_memories");
    const reads = ["list_memory_scopes", "list_memories", "get_memory", "search_memories"];
    expect(await list(true, ["mcp:memory:read"])).toEqual(reads);
    expect(await list(true, ["mcp:memory:write"])).toEqual([...reads, "save_memory", "delete_memory"]);
    expect(await list(false, ["mcp:memory:write"])).not.toContain("search_memories");
    expect(await list(true, [])).not.toContain("search_memories");
    // The memory guide reaches clients at discovery, only with memory access.
    expect((await rpc(true, ["mcp:memory:read"], "server/discover")).result?.instructions).toContain("search_memories");
    expect((await rpc(true, ["mcp:read"], "server/discover")).result).not.toHaveProperty("instructions");
  });
});

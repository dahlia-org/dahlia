import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { createApp } from "../src/app";
import { createWorkerHandler } from "../src/worker";
import { createServerMcpHandler } from "../src/mcp";
import type { AppConfig } from "../src/config";
import type { MemoryGenerator } from "../src/agent/context-service";
import { MeetingSyncService } from "../src/sync/service";
import { WorkspaceMemoryService } from "../src/memory/service";
import { DahliaMemory, memorySaveSchema } from "../src/memory/dahlia";
import { routeMemory } from "../src/memory/router";
import { createDahliaMemoryTools } from "../src/memory/dahlia-tools";
import { meetingRequestContext } from "../src/agent/tools";
import { MEMORY_READ_SCOPE, MEMORY_WRITE_SCOPE } from "../src/auth/scopes";
import { decodeId, encodeId } from "../src/typeid";
import { uuidV7 } from "../src/id";
import { seedHeaderIdentity, testOrganizationID } from "./public-test-client";

const signal = new AbortController().signal;
const directories: string[] = [];
afterEach(() => { directories.splice(0).forEach((path) => rmSync(path, { recursive: true, force: true })); });
async function fixture() {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-personal-memory-")); directories.push(directory);
  const file = join(directory, "test.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite", databaseUrl: `file:${file}`,
    baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024,
    hindsight: { url: "https://memory.example", auth: "bearer", apiKey: "test", bankPrefix: "test" } };
  const app = createNodeApplicationStore(config); await app.migrate();
  const owner = { userId: uuidV7(), email: "memory-owner@example.com", source: "header" as const };
  const stranger = { userId: uuidV7(), email: "memory-stranger@example.com", source: "header" as const };
  await seedHeaderIdentity(app, file, owner); await seedHeaderIdentity(app, file, stranger);
  const sync = new MeetingSyncService(app.sync), workspace = uuidV7();
  await sync.commitTransaction(owner, { schemaVersion: 3, workspaceId: workspace, id: uuidV7(), createdAt: new Date().toISOString(), operations: [{
    id: uuidV7(), entity: "workspace", action: "create", entityId: workspace, baseRevision: null,
    data: { organizationId: testOrganizationID, name: "Team", createdAt: new Date().toISOString() },
  }] });
  const documents = new Map<string, Map<string, string>>();
  const transport = vi.fn<typeof fetch>(async (input, init) => {
    const path = new URL(String(input)).pathname;
    const bank = path.split("/banks/")[1]!.split("/")[0]!;
    const docs = documents.get(bank) ?? new Map<string, string>(); documents.set(bank, docs);
    const body = (init?.body ? JSON.parse(String(init.body)) : {}) as { items: Array<{ document_id: string; content: string }>; operation_id: string };
    if (path.endsWith("/config")) return Response.json({});
    if (path.endsWith("/memories") && init?.method === "POST") { for (const item of body.items) docs.set(item.document_id, item.content); return Response.json({ operation_id: body.operation_id }); }
    if (path.includes("/operations/")) return Response.json({ status: "completed" });
    if (path.endsWith("/memories/recall")) return Response.json({ results: [...docs].map(([id, text]) => ({ id, text, document_id: id })) });
    if (path.endsWith("/reflect")) return Response.json({ text: "Hypothesis", based_on: { memories: [...docs.keys()].map((id) => ({ id, text: "claim" })), mental_models: [] } });
    if (path.includes("/memories/")) return Response.json({ document_id: path.split("/").at(-1), state: "valid" });
    if (path.endsWith("/mental-models") && init?.method === "POST") return Response.json({ operation_id: uuidV7() });
    if (path.endsWith("/mental-models")) return Response.json({ items: [] });
    if (path.includes("/mental-models/")) return Response.json({}, { status: 404 });
    if (path.includes("/documents/") && init?.method === "DELETE") { docs.delete(path.split("/").at(-1)!); return new Response(null, { status: 204 }); }
    if (init?.method === "DELETE") { docs.clear(); return new Response(null, { status: 204 }); }
    throw new Error("Unexpected mock operation");
  });
  const personal = new WorkspaceMemoryService(config, app.personalMemory!, sync, app.sync, transport);
  const shared = new WorkspaceMemoryService(config, app.memory!, sync, app.sync, transport);
  const generate = vi.fn().mockResolvedValue({ target: "personal", reason: "personal_preference" });
  const memory = new DahliaMemory({ personal: app.personalMemory!, workspace: app.memory! }, sync, { personal, workspace: shared }, generate as MemoryGenerator);
  const db = new DatabaseSync(file);
  const tick = async () => { db.exec("UPDATE personal_memory_state SET available_at = 0"); await personal.step(owner.userId, signal); };
  const ready = async () => { for (let i = 0; i < 60; i++) { await tick(); if ((await personal.status(owner, owner.userId)).status === "ready") return; } throw new Error("Memory did not settle"); };
  const note = (content: string) => ({ ...memorySaveSchema.parse({ scope: "personal", id: encodeId("sharedMemory", uuidV7()), revision: 0, content }), scope: "personal" as const });
  return { app, config, owner, stranger, workspaceId: encodeId("workspace", workspace), sync, memory, personal, generate, note, db, ready, tick, documents,
    close: () => { db.close(); void app.close?.(); } };
}

describe("Dahlia Memory", () => {
  it("shares canonical personal notes across clients, enforces revisions and protects human edits without Hindsight", async () => {
    const f = await fixture();
    try {
      const memory = new DahliaMemory(f.memory.stores, f.sync, {});
      const input = f.note("Prefer concise answers 100% of the time");
      const impersonated = { ...f.owner, impersonated: true };
      await expect(memory.save(impersonated, input)).rejects.toMatchObject({ code: "impersonation_read_only" });
      await expect(memory.configure(impersonated, { scope: "personal", enabled: true })).rejects.toMatchObject({ status: 403 });
      await expect(memory.delete(impersonated, { ...input, revision: 1, explicit: true })).rejects.toMatchObject({ status: 403 });
      const saved = await memory.save(f.owner, input);
      expect(saved).toMatchObject({ saved: true, scope: "personal", memory: { revision: 1, protected: false } });
      expect(await memory.save(f.owner, input)).toEqual(saved);
      expect((await memory.list(f.stranger, { scope: "personal" })).items).toEqual([]);
      await expect(memory.get(f.stranger, input)).rejects.toMatchObject({ code: "memory_not_found" });
      expect((await memory.list(f.owner, { scope: "personal", query: "100%" })).items).toHaveLength(1);
      await memory.save(f.owner, { ...input, revision: 1, content: "Human correction", explicit: true }, "human");
      await expect(memory.save(f.owner, { ...input, revision: 2, content: "Automatic overwrite" })).rejects.toMatchObject({ code: "memory_human_edit_protected" });
      await expect(memory.save(f.owner, { ...input, revision: 1, content: "Stale", explicit: true })).rejects.toMatchObject({ code: "memory_revision_conflict" });
      const result = await memory.search(f.owner, { scope: "personal", workspaceId: f.workspaceId, query: "Human" }, false, signal);
      expect(result.searchedScopes).toEqual([{ scope: "personal" }]);
      expect(result.results[0]).not.toHaveProperty("workspaceId");
      expect(result.results[0]!.result).toMatchObject({ unavailable: true, canonical: { items: [{ content: "Human correction" }] } });
      await memory.delete(f.owner, { ...input, revision: 2, explicit: true });
      expect((await memory.list(f.owner, { scope: "personal" })).items).toEqual([]);
    } finally { f.close(); }
  });
  it.each(["personal", "workspace"] as const)("does not accept a stale human save without protection in %s", async (scope) => {
    const f = await fixture();
    try {
      const store = f.memory.stores[scope];
      const scopeId = scope === "personal" ? f.owner.userId : decodeId("workspace", f.workspaceId);
      const input = { id: uuidV7(), revision: 0, content: "Original" };
      const save = (value: typeof input, actor: "human" | "agent") => store.saveNote(f.owner.userId, scopeId, value, actor, false, true);
      await save(input, "agent");
      const edit = { ...input, revision: 1, content: "Same correction" };
      const automatic = await save(edit, "agent");
      expect(await save(edit, "agent")).toEqual(automatic);
      await expect(save(edit, "human")).rejects.toMatchObject({ code: "memory_revision_conflict" });
      const confirmed = { ...edit, revision: 2 };
      const human = await save(confirmed, "human");
      expect(human).toMatchObject({ revision: 3, protected: true });
      expect(await save(confirmed, "human")).toEqual(human);
      await expect(save({ ...confirmed, revision: 3, content: "Automatic overwrite" }, "agent")).rejects.toMatchObject({ code: "memory_human_edit_protected" });
    } finally { f.close(); }
  });
  it("routes only within context and never treats a workspace suggestion as sharing permission", async () => {
    const f = await fixture();
    try {
      const input = { ...f.note("Team decision"), scope: "auto" as const, workspaceId: f.workspaceId };
      f.generate.mockResolvedValue({ target: "workspace", reason: "team_decision" });
      expect(await f.memory.save(f.owner, input)).toMatchObject({ saved: false, suggestedScope: "workspace" });
      expect((await f.memory.list(f.owner, { scope: "workspace", workspaceId: f.workspaceId })).items).toEqual([]);
      expect(await f.memory.save(f.owner, { ...input, explicit: true })).toMatchObject({ saved: true, scope: "workspace" });
      f.generate.mockResolvedValue({ target: "both", reason: "mixed" });
      expect(await f.memory.save(f.owner, { ...input, explicit: true })).toMatchObject({ saved: false, suggestedScope: "both" });
      f.generate.mockRejectedValue(new Error("provider failed"));
      expect(await f.memory.save(f.owner, input)).toMatchObject({ saved: false, suggestedScope: "uncertain" });
      const result = await f.memory.search(f.owner, { scope: "auto", workspaceId: f.workspaceId, query: "question" }, false, signal);
      expect(result.searchedScopes.map((s) => s.scope)).toEqual(["personal", "workspace"]);
      expect((await f.memory.search(f.owner, { scope: "auto", query: "question" }, false, signal)).searchedScopes).toEqual([{ scope: "personal" }]);
      await expect(f.memory.save(f.stranger, { ...input, scope: "workspace", explicit: true })).rejects.toMatchObject({ status: 404 });
      const calls = f.generate.mock.calls.length;
      await f.memory.list(f.owner, { scope: "personal" });
      await f.memory.save(f.owner, f.note("Explicit personal"));
      expect(f.generate.mock.calls).toHaveLength(calls);
      await expect(f.memory.save(f.owner, { ...input, revision: 1 })).rejects.toMatchObject({ code: "memory_update_scope_required" });
    } finally { f.close(); }
  });
  it("rechecks Workspace permission after a multi-bank search completes", async () => {
    const f = await fixture();
    try {
      const getWorkspace = vi.spyOn(f.sync, "getWorkspace");
      const memory = new DahliaMemory(f.memory.stores, f.sync, { workspace: { search: async () => {
        getWorkspace.mockResolvedValue(null);
        return { sources: [], hypothesis: null, coverage: "ready" };
      } } as unknown as WorkspaceMemoryService });
      await expect(memory.search(f.owner, { scope: "auto", workspaceId: f.workspaceId, query: "x" }, false, signal)).rejects.toMatchObject({ status: 404 });
    } finally { f.close(); }
  });
  it.each(["edit", "delete", "pause", "unconfigured"])("revalidates an earlier bank after a slower search during %s", async (action) => {
    const f = await fixture();
    try {
      const input = f.note("Original lesson");
      await f.memory.save(f.owner, input);
      if (action !== "unconfigured") {
        await f.memory.configure(f.owner, { scope: "personal", enabled: true });
        await f.ready();
      }
      let personalFinished!: () => void;
      const finished = new Promise<void>((resolve) => { personalFinished = resolve; });
      const search = f.personal.search.bind(f.personal);
      vi.spyOn(f.personal, "search").mockImplementation(async (...args) => {
        try { return await search(...args); } finally { personalFinished(); }
      });
      const workspace = { search: async () => {
        await finished;
        if (action === "pause") await f.memory.configure(f.owner, { scope: "personal", enabled: false });
        else if (action === "edit") await f.memory.save(f.owner, { ...input, revision: 1, content: "Corrected lesson" });
        else await f.memory.delete(f.owner, { ...input, revision: 1, explicit: true });
        return { sources: [], hypothesis: null, coverage: "ready" };
      } } as unknown as WorkspaceMemoryService;
      const memory = new DahliaMemory(f.memory.stores, f.sync, { personal: f.personal, workspace });
      const found = await memory.search(f.owner, { scope: "auto", workspaceId: f.workspaceId, query: "lesson" }, true, signal);
      const result = found.results[0]!.result;
      expect(result).toMatchObject({ unavailable: true });
      expect(result).not.toHaveProperty("sources");
      expect(result).not.toHaveProperty("hypothesis");
      expect(result).toMatchObject({ canonical: { items: action === "delete" || action === "unconfigured" ? [] : [
        expect.objectContaining({ content: action === "edit" ? "Corrected lesson" : "Original lesson" }),
      ] } });
    } finally { f.close(); }
  });
  it("indexes personal memory separately and excludes edited/deleted sources before cleanup completes", async () => {
    const f = await fixture();
    try {
      const input = f.note("Original private lesson");
      await f.memory.save(f.owner, input);
      await f.memory.configure(f.owner, { scope: "personal", enabled: true });
      await f.ready();
      const bank = `test-user-${f.owner.userId}`;
      expect([...f.documents.keys()]).toEqual([bank]);
      for (const reflect of [false, true]) {
        const found = await f.memory.search(f.owner, { scope: "personal", workspaceId: f.workspaceId, query: "lesson" }, reflect, signal);
        expect(found.searchedScopes).toEqual([{ scope: "personal" }]);
        expect(found.results[0]).not.toHaveProperty("workspaceId");
        expect(found.results[0]!.result).toMatchObject({ sources: [{ scope: "personal", workspace_id: null }] });
      }
      expect((await f.personal.search(f.owner, f.owner.userId, "lesson", true, signal))).toMatchObject({ sources: [{ scope: "personal", workspace_id: null }], hypothesis: "Hypothesis" });
      await f.memory.save(f.owner, { ...input, revision: 1, content: "New private lesson" });
      expect((await f.personal.search(f.owner, f.owner.userId, "lesson", true, signal)).sources).toEqual([]);
      await f.ready();
      expect((await f.personal.search(f.owner, f.owner.userId, "lesson", false, signal)).sources[0]!.canonicalExcerpt).toContain("New private lesson");
      await f.memory.delete(f.owner, { ...input, revision: 2, explicit: true });
      expect((await f.personal.search(f.owner, f.owner.userId, "lesson", true, signal)).sources).toEqual([]);
      await f.ready(); expect(f.documents.get(bank)?.size).toBe(0);
      await expect(f.personal.search(f.stranger, f.owner.userId, "lesson", false, signal)).rejects.toMatchObject({ status: 404 });
    } finally { f.close(); }
  });
  it("keeps personal cleanup work after account deletion", async () => {
    const f = await fixture();
    try {
      await f.memory.save(f.stranger, f.note("Private"));
      await f.personal.configure(f.stranger, f.stranger.userId, true); for (let i = 0; i < 30; i++) { f.db.exec("UPDATE personal_memory_state SET available_at = 0"); await f.personal.step(f.stranger.userId, signal); }
      f.db.prepare('DELETE FROM "user" WHERE id = ?').run(f.stranger.userId);
      f.db.exec("UPDATE personal_memory_state SET available_at = 0"); await f.personal.step(f.stranger.userId, signal);
      expect(f.documents.get(`test-user-${f.stranger.userId}`)?.size).toBe(0);
      expect(f.db.prepare("SELECT * FROM personal_memory_state").all()).toEqual([]);
    } finally { f.close(); }
  });
  it("requires dedicated scopes for MCP and shares the same tools with the internal agent", async () => {
    const f = await fixture();
    try {
      const workingMemory = { settings: async () => ({ revision: 0, automatic: true, capacityReached: false, manual: "A private note", learned: "" }),
        editSettings: async (_identity: unknown, input: { content?: string }) => ({ revision: 1, automatic: true, capacityReached: false, manual: input.content ?? "", learned: "" }) };
      const handler = createServerMcpHandler(f.config, f.sync, undefined, undefined, undefined, f.memory, workingMemory as never);
      const list = async (scopes: string[]) => {
        const response = await handler.fetch(new Request("http://localhost:5173/mcp", { method: "POST", headers: { "Mcp-Method": "tools/list", "MCP-Protocol-Version": "2026-07-28", "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: { _meta: { "io.modelcontextprotocol/clientCapabilities": {}, "io.modelcontextprotocol/clientInfo": { name: "test", version: "1" }, "io.modelcontextprotocol/protocolVersion": "2026-07-28" } } }) }), { authInfo: { token: "test", clientId: "test", scopes, extra: { identity: f.owner } } });
        return response.text();
      };
      expect(await list(["mcp"])).not.toContain('"save_memory"');
      expect(await list(["mcp"])).not.toContain('"list_memories"');
      const read = await list([MEMORY_READ_SCOPE]); expect(read).toContain('"list_memories"'); expect(read).toContain('"get_working_memory"');
      expect(read).not.toContain('"save_memory"'); expect(read).not.toContain('"update_working_memory"');
      expect(await list([MEMORY_WRITE_SCOPE])).toContain('"save_memory"');
      expect(await list([MEMORY_WRITE_SCOPE])).toContain('"update_working_memory"');
      const call = async (scopes: string[], name: string, args: unknown, expiresAt = Date.now() / 1000 + 60) => {
        const body = JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name, arguments: args,
          _meta: { "io.modelcontextprotocol/clientCapabilities": {}, "io.modelcontextprotocol/clientInfo": { name: "test", version: "1" }, "io.modelcontextprotocol/protocolVersion": "2026-07-28" } } });
        const response = await handler.fetch(new Request("http://localhost:5173/mcp", { method: "POST", headers: {
          "Content-Type": "application/json", "Mcp-Method": "tools/call", "Mcp-Name": name, "Mcp-Protocol-Version": "2026-07-28" }, body }),
        { authInfo: { token: "test", clientId: "test", scopes, expiresAt, extra: { identity: f.owner } } });
        const value: { result?: { isError?: boolean; content: Array<{ text: string }> }; error?: unknown } = await response.json();
        return value;
      };
      const wireNote = f.note("From remote MCP");
      expect((await call([MEMORY_READ_SCOPE], "get_working_memory", {})).result?.content[0]?.text).toContain("A private note");
      expect((await call([MEMORY_READ_SCOPE], "update_working_memory", { section: "manual", content: "changed", revision: 0, explicit: true })).error).toBeDefined();
      expect((await call([MEMORY_WRITE_SCOPE], "update_working_memory", { section: "manual", content: "changed", revision: 0, explicit: true })).result?.content[0]?.text).toContain("changed");
      expect((await call([MEMORY_READ_SCOPE], "save_memory", wireNote)).error).toBeDefined();
      expect((await call([MEMORY_WRITE_SCOPE], "save_memory", wireNote)).result?.content[0]?.text).toContain('"saved":true');
      const expired = await call([MEMORY_WRITE_SCOPE], "delete_memory", { ...wireNote, revision: 1, explicit: true }, 1);
      expect(expired.error ?? expired.result?.isError).toBeTruthy();
      expect((await f.memory.get(f.owner, wireNote)).memory.content).toBe("From remote MCP");
      await f.memory.delete(f.owner, { ...wireNote, revision: 1, explicit: true });
      const tools = createDahliaMemoryTools(f.memory);
      const input = f.note("From Claude Code");
      if (!("save_memory" in tools)) throw new Error("Missing write tool");
      await tools.save_memory.execute!(input, { requestContext: meetingRequestContext(f.owner), abortSignal: signal } as never);
      const found = await tools.list_memories.execute!({ scope: "personal" }, { requestContext: meetingRequestContext(f.owner), abortSignal: signal } as never);
      expect(found).toMatchObject({ items: [{ content: "From Claude Code" }] });
      await expect(tools.list_memories.execute!({ scope: "workspace", workspaceId: encodeId("workspace", uuidV7()) }, {
        requestContext: meetingRequestContext(f.owner, f.workspaceId), abortSignal: signal } as never)).rejects.toThrow();
    } finally { f.close(); }
  });
  it("updates private Working Memory in a workspace-pinned AI chat", async () => {
    const f = await fixture();
    try {
      const { workingMemoryEditSchema } = await import("../src/agent/context-model");
      const editSettings = vi.fn(async (_identity, input) => workingMemoryEditSchema.parse(input));
      const tools = createDahliaMemoryTools(f.memory, true, { editSettings } as unknown as import("../src/agent/context-store").ChatMemoryStore);
      if (!("update_working_memory" in tools)) throw new Error("Missing working memory tool");
      for (const input of [{ section: "manual", content: "User notes", revision: 0, explicit: true },
        { section: "learned", content: "Learned notes", revision: 1, explicit: true },
        { section: "settings", automatic: false, revision: 2, explicit: true }]) {
        expect(await tools.update_working_memory!.execute!(input as never, {
          requestContext: meetingRequestContext(f.owner, decodeId("workspace", f.workspaceId)), abortSignal: signal,
        } as never)).toEqual(input);
      }
      expect(editSettings).toHaveBeenCalledTimes(3);
    } finally { f.close(); }
  });
  it.each(["route", "explicit-save", "delete", "cancel"])("checks authorization immediately before mutation after %s", async (action) => {
    const f = await fixture();
    try {
      const tools = createDahliaMemoryTools(f.memory);
      if (!("save_memory" in tools) || !("delete_memory" in tools)) throw new Error("Missing write tools");
      let authorized = true;
      const controller = new AbortController();
      const authorize = async () => { if (!authorized) throw new Error("token_expired"); };
      const context = { requestContext: meetingRequestContext(f.owner, undefined, authorize), abortSignal: controller.signal } as never;
      const note = f.note("Must not commit");
      if (action === "route" || action === "cancel") {
        f.generate.mockImplementation(async () => {
          if (action === "cancel") controller.abort(); else authorized = false;
          return { target: "personal", reason: "preference" };
        });
        await expect(tools.save_memory.execute!({ ...note, scope: "auto" }, context)).rejects.toThrow();
        await expect(f.memory.get(f.owner, note)).rejects.toMatchObject({ code: "memory_not_found" });
      } else {
        const input = { ...note, scope: "workspace" as const, workspaceId: f.workspaceId, explicit: true };
        if (action === "delete") await f.memory.save(f.owner, input);
        const getWorkspace = f.sync.getWorkspace.bind(f.sync);
        const lookup = vi.spyOn(f.sync, "getWorkspace").mockImplementation(async (...args) => {
          const result = await getWorkspace(...args); authorized = false; return result;
        });
        const call = action === "delete" ? tools.delete_memory.execute!({ scope: input.scope, workspaceId: input.workspaceId, id: input.id, revision: 1, explicit: true }, context) : tools.save_memory.execute!(input, context);
        await expect(call).rejects.toThrow("token_expired");
        lookup.mockRestore();
        if (action === "delete") expect((await f.memory.get(f.owner, input)).memory.revision).toBe(1);
        else await expect(f.memory.get(f.owner, input)).rejects.toMatchObject({ code: "memory_not_found" });
      }
    } finally { f.close(); }
  });
  it.each(["save", "delete"])("acknowledges a committed %s even if authorization expires afterward", async (action) => {
    const f = await fixture();
    try {
      const tools = createDahliaMemoryTools(f.memory);
      if (!("save_memory" in tools) || !("delete_memory" in tools)) throw new Error("Missing write tools");
      const input = f.note("Committed");
      if (action === "delete") await f.memory.save(f.owner, input);
      let authorized = true;
      const authorize = async () => { if (!authorized) throw new Error("token_expired"); };
      const context = { requestContext: meetingRequestContext(f.owner, undefined, authorize), abortSignal: signal } as never;
      const store = f.memory.stores.personal;
      if (action === "save") {
        const save = store.saveNote.bind(store);
        vi.spyOn(store, "saveNote").mockImplementation(async (...args) => { const result = await save(...args); authorized = false; return result; });
        expect(await tools.save_memory.execute!(input, context)).toMatchObject({ saved: true });
        expect((await f.memory.get(f.owner, input)).memory.content).toBe("Committed");
      } else {
        const remove = store.deleteNote.bind(store);
        vi.spyOn(store, "deleteNote").mockImplementation(async (...args) => { await remove(...args); authorized = false; });
        expect(await tools.delete_memory.execute!({ scope: "personal", id: input.id, revision: 1, explicit: true }, context)).toMatchObject({ deleted: true });
        await expect(f.memory.get(f.owner, input)).rejects.toMatchObject({ code: "memory_not_found" });
      }
      await expect(tools.list_memories.execute!({ scope: "personal" }, context)).rejects.toThrow("token_expired");
    } finally { f.close(); }
  });
  it("accepts only UUIDv7 memory IDs at the shared save boundary", () => {
    const input = { scope: "personal", content: "x", revision: 0 };
    expect(memorySaveSchema.safeParse({ ...input, id: encodeId("sharedMemory", uuidV7()) }).success).toBe(true);
    for (const id of ["smem_invalid", encodeId("meeting", uuidV7()),
      encodeId("sharedMemory", "00000000-0000-4000-8000-000000000000"),
      encodeId("sharedMemory", "00000000-0000-7000-0000-000000000000")]) {
      expect(memorySaveSchema.safeParse({ ...input, id }).success).toBe(false);
    }
  });
  it.each(["node", "worker"])("exposes canonical Web memory without analysis (%s)", async (runtime) => {
    const f = await fixture();
    try {
      const application = createApp({ config: { ...f.config, hindsight: undefined }, authStore: f.app });
      const worker = createWorkerHandler(async () => application);
      const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
      const app = { request: (path: string, init: RequestInit) => runtime === "node" ? application.request(path, init)
        : fetchWorker(new Request(new URL(path, f.config.baseUrl), init), {} as Cloudflare.Env, {} as ExecutionContext) };
      const input = f.note("Web memory");
      const request = (path: string, method = "GET", value?: unknown, email = f.owner.email, workspaceId?: string) => app.request(workspaceId
        ? `/api/v1/workspaces/${workspaceId}/memory${path}` : `/api/v1/user/memory${path}`,
      { method, headers: { "Content-Type": "application/json", "X-Forwarded-Email": email }, ...(value === undefined ? {} : { body: JSON.stringify(value) }) });
      const save = { id: input.id, content: input.content, revision: 0, explicit: true };
      for (const workspaceId of [undefined, f.workspaceId]) {
        expect((await request("/notes", "POST", save, f.owner.email, workspaceId)).status).toBe(200);
        expect(await (await request("/notes", "GET", undefined, f.owner.email, workspaceId)).json()).toMatchObject({ items: [{ content: "Web memory", protected: true }] });
        expect(await (await request(`/notes/${input.id}`, "GET", undefined, f.owner.email, workspaceId)).json()).toMatchObject({ memory: { revision: 1 } });
        const edit = { content: "Edited while analysis is off", revision: 1, explicit: true };
        expect((await request(`/notes/${input.id}`, "PATCH", edit, f.owner.email, workspaceId)).status).toBe(200);
        expect((await request(`/notes/${input.id}`, "PATCH", { ...edit, content: "Stale update" }, f.owner.email, workspaceId)).status).toBe(409);
        expect((await request(`/notes/${input.id}`, "PATCH", { ...edit, revision: 0 }, f.owner.email, workspaceId)).status).toBe(400);
        expect((await request(`/notes/${input.id}?revision=2`, "DELETE", undefined, f.owner.email, workspaceId)).status).toBe(400);
        expect((await request(`/notes/${input.id}?revision=9007199254740992&explicit=true`, "DELETE", undefined, f.owner.email, workspaceId)).status).toBe(400);
        expect((await request(`/notes/${input.id}?revision=2&explicit=true`, "DELETE", undefined, f.owner.email, workspaceId)).status).toBe(200);
        if (workspaceId) {
          expect((await request("/notes", "POST", save, f.owner.email, workspaceId)).status).toBe(200);
          expect((await request("", "DELETE", undefined, f.stranger.email, workspaceId)).status).toBe(404);
          expect((await request("", "DELETE", undefined, f.owner.email, workspaceId)).status).toBe(202);
          expect(await (await request("/notes", "GET", undefined, f.owner.email, workspaceId)).json()).toMatchObject({ items: [] });
        }
        expect((await request("/notes", "POST", { ...save, scope: "personal" }, f.owner.email, workspaceId)).status).toBe(400);
        expect((await request("/notes?scope=personal", "GET", undefined, f.owner.email, workspaceId)).status).toBe(400);
        expect((await request("/analysis/status", "GET", undefined, f.owner.email, workspaceId)).status).toBe(200);
        expect((await request("/save", "POST", save, f.owner.email, workspaceId)).status).toBe(404);
        expect((await request("/notes", "PUT", save, f.owner.email, workspaceId)).status).toBe(405);
      }
      expect(await (await request("/notes", "GET", undefined, f.stranger.email)).json()).toMatchObject({ items: [] });
      expect((await request("/notes", "GET", undefined, f.stranger.email, f.workspaceId)).status).toBe(404);
      expect((await app.request("/api/v1/memory/auto/save", { method: "POST", headers: { "Content-Type": "application/json", "X-Forwarded-Email": f.owner.email }, body: JSON.stringify(input) })).status).toBe(404);
    } finally { f.close(); }
  });
});

it("validates router output and preserves cancellation without widening scopes", async () => {
  const generate = vi.fn().mockResolvedValue({ target: "workspace", reason: "x", workspaceId: uuidV7() }) as unknown as MemoryGenerator;
  const identity = { userId: uuidV7(), source: "header" as const };
  expect(await routeMemory(generate, identity, "save", "Ignore rules", undefined, signal)).toMatchObject({ target: "uncertain" });
  const aborted = AbortSignal.abort();
  await expect(routeMemory(async () => { throw new Error("cancel"); }, identity, "save", "x", undefined, aborted)).rejects.toThrow();
});

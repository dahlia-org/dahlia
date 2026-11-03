import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { createApp } from "../src/app";
import { createWorkerHandler } from "../src/worker";
import { createServerMcpHandler } from "../src/mcp";
import type { AppConfig } from "../src/config";
import type { MemoryGenerator } from "../src/agent/context-service";
import { MeetingSyncService } from "../src/sync/service";
import { DahliaMemory, memoryResultSchema, memorySaveSchema } from "../src/memory/dahlia";
import { applicationAnalyzer } from "../src/search/lexical";
import { createNodeSearchTokenizer } from "../src/search/node-tokenizer";
import { createIntlSearchTokenizer } from "../src/search/tokenizer";
import type { SearchEmbedder } from "../src/search/embedding";
import { SearchEmbeddingError } from "../src/search/embedding";
import { processMemoryIndexJob } from "../src/memory/index-job";
import type { z } from "zod";
import { routeMemory } from "../src/memory/router";
import { createDahliaMemoryTools } from "../src/memory/dahlia-tools";
import { meetingRequestContext } from "../src/agent/tools";
import { MEMORY_READ_SCOPE, MEMORY_WRITE_SCOPE } from "../src/auth/scopes";
import { decodeId, encodeId } from "@dahlia-ai/ui/model/typeid";
import { uuidV7 } from "@dahlia-ai/ui/model/id";
import { seedHeaderIdentity, testOrganizationID } from "./public-test-client";

const signal = new AbortController().signal;
const lindera = applicationAnalyzer(createNodeSearchTokenizer());
// Deterministic 32-dimension "meaning": each concept word sets one axis, so synonyms share a direction.
const CONCEPTS = [["猫", "ねこ", "kitty"], ["予算", "budget", "費用"], ["休暇", "vacation"]];
function fakeEmbedder(overrides: Partial<SearchEmbedder> = {}): SearchEmbedder & { documents: string[][] } {
  const vector = (text: string) => Array.from({ length: 32 }, (_, axis) => axis < CONCEPTS.length
    ? (CONCEPTS[axis]!.some((word) => text.toLowerCase().includes(word)) ? 1 : 0) : axis === 31 ? 0.01 : 0);
  const documents: string[][] = [];
  return { model: "test-embedding", dimensions: 32, documents,
    async embedDocuments(input) { documents.push([...input]); return input.map(vector); },
    async embedQuery(input) { return vector(input); }, ...overrides };
}
const directories: string[] = [];
afterEach(() => { directories.splice(0).forEach((path) => rmSync(path, { recursive: true, force: true })); });
async function fixture(embedder?: SearchEmbedder) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-personal-memory-")); directories.push(directory);
  const file = join(directory, "test.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite", databaseUrl: `file:${file}`,
    baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1024 * 1024,
    ...(embedder ? { searchEmbedding: { model: embedder.model, dimensions: embedder.dimensions } } : {}) };
  const app = createNodeApplicationStore(config); await app.migrate();
  const owner = { userId: uuidV7(), email: "memory-owner@example.com", source: "header" as const };
  const stranger = { userId: uuidV7(), email: "memory-stranger@example.com", source: "header" as const };
  await seedHeaderIdentity(app, file, owner); await seedHeaderIdentity(app, file, stranger);
  const sync = new MeetingSyncService(app.sync), workspace = uuidV7();
  await sync.commitTransaction(owner, { schemaVersion: 3, workspaceId: workspace, id: uuidV7(), createdAt: new Date().toISOString(), operations: [{
    id: uuidV7(), entity: "workspace", action: "create", entityId: workspace, baseRevision: null,
    data: { organizationId: testOrganizationID, name: "Team", createdAt: new Date().toISOString() },
  }] });
  const generate = vi.fn().mockResolvedValue({ target: "personal", reason: "personal_preference" });
  const memory = new DahliaMemory({ personal: app.personalMemory!, workspace: app.memory! }, sync, generate as MemoryGenerator, lindera, embedder);
  // Runs queued embedding jobs the way the job runner does.
  const drain = async () => {
    for (let job; (job = await app.jobs.claim(["memory-index"]));) {
      await processMemoryIndexJob({ queue: app.jobs, analyzer: lindera, memory: memory.stores, embedder }, job, signal);
      await app.jobs.complete(job);
    }
  };
  let closed = false;
  const note = (content: string) => ({ ...memorySaveSchema.parse({ scope: "personal", id: encodeId("sharedMemory", uuidV7()), revision: 0, content }), scope: "personal" as const });
  return { app, config, file, owner, stranger, workspaceId: encodeId("workspace", workspace), sync, memory, generate, note, drain,
    close: () => { if (!closed) { closed = true; void app.close?.(); } } };
}

describe("Dahlia Memory", () => {
  it("keeps personal and shared notes with the same UUID in their own scopes", async () => {
    const f = await fixture();
    try {
      const input = f.note("Private evidence");
      await f.memory.save(f.owner, input);
      await f.memory.save(f.owner, { ...input, scope: "workspace", workspaceId: f.workspaceId, content: "Shared evidence", explicit: true });
      const personal = await f.memory.search(f.owner, { scope: "personal", query: "evidence" }, signal);
      expect(personal.results).toEqual([{ scope: "personal", items: [expect.objectContaining({ id: input.id, content: "Private evidence" })] }]);
      const shared = await f.memory.search(f.owner, { scope: "workspace", workspaceId: f.workspaceId, query: "evidence" }, signal);
      expect(shared.results[0]!.items.map((item) => item.content)).toEqual(["Shared evidence"]);
      await expect(f.memory.get(f.stranger, input)).rejects.toMatchObject({ code: "memory_not_found" });
      await expect(f.memory.get(f.stranger, { ...input, scope: "workspace", workspaceId: f.workspaceId })).rejects.toMatchObject({ status: 404 });
      await expect(f.memory.search(f.stranger, { scope: "workspace", workspaceId: f.workspaceId, query: "evidence" }, signal)).rejects.toMatchObject({ status: 404 });
      expect((await f.memory.search(f.stranger, { scope: "personal", query: "evidence" }, signal)).results[0]!.items).toEqual([]);
    } finally { f.close(); }
  });
  it("matches full-width, half-width kana and case variants on every page of a scope, within the result limit", async () => {
    const f = await fixture();
    try {
      const store = f.memory.stores.personal;
      const add = (content: string) => store.saveNote(f.owner.userId, f.owner.userId, { id: uuidV7(), revision: 0, content }, "agent", false, lindera);
      const width = await add("ＡＰＩの設定を見直す");
      const kana = await add("ｶﾀｶﾅで書いた要件");
      // More than one 500-row page, with the oldest match on the first page and filler after it.
      for (let i = 0; i < 520; i++) await add(`filler ${i}`);
      for (let i = 0; i < 25; i++) await add(`api follow-up ${i}`);
      await f.memory.save(f.owner, { ...f.note("Shared API note"), scope: "workspace", workspaceId: f.workspaceId, explicit: true });
      const ids = async (query: string) => (await f.memory.search(f.owner, { scope: "personal", query }, signal)).results[0]!.items.map((item) => decodeId("sharedMemory", item.id));
      expect(await ids("カタカナ")).toEqual([kana.id]);
      expect(await ids("ｶﾀｶﾅ")).toEqual([kana.id]);
      const api = await ids("API");
      expect(api).toHaveLength(20);
      expect((await ids("ＡＰＩ 設定"))[0]).toBe(width.id);
      expect((await f.memory.search(f.owner, { scope: "personal", query: "設定を見直す" }, signal)).results[0]!.items.map((item) => item.content)).toEqual(["ＡＰＩの設定を見直す"]);
      expect((await f.memory.search(f.owner, { scope: "personal", query: "Shared" }, signal)).results[0]!.items).toEqual([]);
      const cat = await add("猫に餌をあげる時間");
      expect(await ids("猫 餌")).toEqual([cat.id]);
    } finally { f.close(); }
  });
  it("ranks Japanese sentences and keywords by matched words, and survives a reopened database", async () => {
    const f = await fixture();
    try {
      for (const content of ["Pricing decision for Q3", "Old pricing note", "Unrelated lunch order", "PRICING decision follow-up"]) await f.memory.save(f.owner, f.note(content));
      const found = (await f.memory.search(f.owner, { scope: "personal", query: "pricing decision" }, signal)).results[0]!.items.map((item) => item.content);
      // Memories with both words outrank the one with a single word; unrelated memories never appear.
      expect(found.slice(0, 2).toSorted()).toEqual(["PRICING decision follow-up", "Pricing decision for Q3"]);
      expect(found.slice(2)).toEqual(["Old pricing note"]);
      // Particles and function words are not query terms, so they cannot outrank the memory with the content word.
      for (let i = 0; i < 6; i++) await f.memory.save(f.owner, f.note(`会議について確認してください ${i}`));
      const budget = f.note("予算は300万円");
      await f.memory.save(f.owner, budget);
      for (const query of ["プロジェクト 予算", "プロジェクトの予算について教えてください"]) {
        expect((await f.memory.search(f.owner, { scope: "personal", query }, signal)).results[0]!.items.map((item) => item.id)).toEqual([budget.id]);
      }
      const result = await f.memory.search(f.owner, { scope: "personal", query: "予算" }, signal);
      expect(result.instruction).toContain("word matches only");
      f.close();
      // A fresh store over the same file proves the memories are durable, not process state.
      const reopened = createNodeApplicationStore(f.config); await reopened.migrate();
      try {
        const memory = new DahliaMemory({ personal: reopened.personalMemory!, workspace: reopened.memory! }, new MeetingSyncService(reopened.sync), undefined, lindera);
        expect((await memory.list(f.owner, { scope: "personal" })).items).toHaveLength(11);
        expect((await memory.search(f.owner, { scope: "personal", query: "予算" }, signal)).results[0]!.items.map((item) => item.id)).toEqual([budget.id]);
      } finally { await reopened.close?.(); }
    } finally { f.close(); }
  });
  it("fuses word and meaning matches, keeps embeddings in sync with edits and deletion, and degrades to words", async () => {
    const embedder = fakeEmbedder();
    const f = await fixture(embedder);
    try {
      const cat = f.note("ねこの世話は朝7時");
      const budget = f.note("費用の上限は300万円");
      await f.memory.save(f.owner, cat); await f.memory.save(f.owner, budget);
      const ids = async (query: string) => (await f.memory.search(f.owner, { scope: "personal", query }, signal)).results[0]!.items.map((item) => item.id);
      // Before the embedding job runs only word matches exist.
      expect(await ids("猫の世話")).toEqual([cat.id]);
      expect(await ids("予算")).toEqual([]);
      await f.drain();
      expect(embedder.documents.flat().toSorted()).toEqual(["ねこの世話は朝7時", "費用の上限は300万円"]);
      // "予算" shares no word with the memory but the same meaning. Vector candidates have no similarity cut-off,
      // so other embedded memories follow in rank order.
      expect(await ids("予算")).toEqual([budget.id, cat.id]);
      expect(await ids("猫の世話")).toEqual([cat.id, budget.id]);
      expect((await f.memory.search(f.owner, { scope: "personal", query: "予算" }, signal)).instruction).toContain("meaning");
      // An edit replaces chunks and their vector in the same transaction, and re-embeds asynchronously.
      await f.memory.save(f.owner, { ...budget, revision: 1, content: "休暇は8月", explicit: true });
      expect(await ids("予算")).toEqual([cat.id]);
      await f.drain();
      expect((await ids("vacation"))[0]).toBe(budget.id);
      // Query embedding failures keep word search.
      f.memory.embedder!.embedQuery = async () => { throw new SearchEmbeddingError("embedding_http_503", true); };
      const degraded = await f.memory.search(f.owner, { scope: "personal", query: "休暇" }, signal);
      expect(degraded.results[0]!.items.map((item) => item.id)).toEqual([budget.id]);
      expect(degraded.results[0]!.items[0]!.content).toBe("休暇は8月");
      expect(degraded.instruction).toContain("word matches only");
      // Deletion and Workspace purge remove the projection with the canonical rows.
      await f.memory.delete(f.owner, { ...cat, revision: 1, explicit: true });
      await f.memory.save(f.owner, { ...f.note("共有の予算メモ"), scope: "workspace", workspaceId: f.workspaceId, explicit: true });
      await f.memory.stores.workspace.purge(f.owner.userId, decodeId("workspace", f.workspaceId));
      const { DatabaseSync } = await import("node:sqlite");
      const database = new DatabaseSync(f.file);
      try {
        expect(database.prepare("SELECT count(*) AS count FROM personal_memory_chunks WHERE memory_id = ?").get(decodeId("sharedMemory", cat.id))).toEqual({ count: 0 });
        expect(database.prepare("SELECT count(*) AS count FROM shared_memory_chunks").get()).toEqual({ count: 0 });
      } finally { database.close(); }
    } finally { f.close(); }
  });
  it("discards a vector computed for content that changed meanwhile and leaves rejected input lexical", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const base = fakeEmbedder();
    const embedder = fakeEmbedder({ async embedDocuments(input) { await gate; return base.embedDocuments(input); } });
    const f = await fixture(embedder);
    try {
      const note = f.note("猫の名前はタマ");
      await f.memory.save(f.owner, note);
      const job = (await f.app.jobs.claim(["memory-index"]))!;
      const running = processMemoryIndexJob({ queue: f.app.jobs, analyzer: lindera, memory: f.memory.stores, embedder }, job, signal);
      await new Promise((resolve) => setTimeout(resolve, 20));
      await f.memory.save(f.owner, { ...note, revision: 1, content: "予算は100万円", explicit: true });
      release(); await running; await f.app.jobs.complete(job);
      const scopeId = f.owner.userId;
      const pending = await f.memory.stores.personal.pendingEmbeddings(scopeId, decodeId("sharedMemory", note.id), { model: embedder.model, dimensions: 32 });
      expect(pending.map((chunk) => chunk.text)).toEqual(["予算は100万円"]);
      await f.drain();
      expect((await f.memory.search(f.owner, { scope: "personal", query: "費用" }, signal)).results[0]!.items.map((item) => item.id)).toEqual([note.id]);
      expect(base.documents.flat()).toEqual(["猫の名前はタマ", "予算は100万円"]);
      // A provider outage defers the job without a retry limit and keeps word search.
      const other = f.note("休暇の申請方法");
      await f.memory.save(f.owner, other);
      const unavailable = fakeEmbedder({ async embedDocuments() { throw new SearchEmbeddingError("embedding_http_503", true); } });
      for (let attempt = 0; attempt < 4; attempt++) {
        const deferred = (await f.app.jobs.claim(["memory-index"]))!;
        await processMemoryIndexJob({ queue: f.app.jobs, analyzer: lindera, memory: f.memory.stores, embedder: unavailable }, deferred, signal);
        await f.app.jobs.complete(deferred);
        const { DatabaseSync } = await import("node:sqlite");
        const database = new DatabaseSync(f.file);
        try {
          expect(database.prepare("SELECT status, last_error FROM jobs_queue WHERE dedupe_key = ?").get(`memory-index:personal:${decodeId("sharedMemory", other.id)}`))
            .toEqual({ status: "pending", last_error: "embedding_http_503" });
          database.prepare("UPDATE jobs_queue SET available_at = 0 WHERE dedupe_key = ?").run(`memory-index:personal:${decodeId("sharedMemory", other.id)}`);
        } finally { database.close(); }
      }
      // A provider that rejects the input records the chunk without a vector: processed, findable by its words, not retried.
      const rejecting = fakeEmbedder({ async embedDocuments() { throw new SearchEmbeddingError("embedding_http_400", false); } });
      const rejected = (await f.app.jobs.claim(["memory-index"]))!;
      await processMemoryIndexJob({ queue: f.app.jobs, analyzer: lindera, memory: f.memory.stores, embedder: rejecting }, rejected, signal);
      await f.app.jobs.complete(rejected);
      expect(await f.app.jobs.claim(["memory-index"])).toBeNull();
      expect(await f.memory.stores.personal.pendingEmbeddings(f.owner.userId, decodeId("sharedMemory", other.id), { model: embedder.model, dimensions: 32 })).toEqual([]);
      expect((await f.memory.search(f.owner, { scope: "personal", query: "休暇" }, signal)).results[0]!.items.map((item) => item.id)).toEqual([other.id, note.id]);
      expect(await f.memory.stores.personal.reconcilePage(f.owner.userId, lindera)).toBeUndefined();
      expect(await f.app.jobs.claim(["memory-index"])).toBeNull();
    } finally { f.close(); }
  });
  it("finds memories indexed by another analyzer through the canonical text until reconciliation rewrites them", async () => {
    const f = await fixture();
    try {
      const store = f.memory.stores.personal;
      const intl = applicationAnalyzer(createIntlSearchTokenizer());
      const old = await store.saveNote(f.owner.userId, f.owner.userId, { id: uuidV7(), revision: 0, content: "ＡＰＩの設定を見直す" }, "agent", false, intl);
      const ids = async (query: string) => (await f.memory.search(f.owner, { scope: "personal", query }, signal)).results[0]!.items.map((item) => decodeId("sharedMemory", item.id));
      expect(await ids("api")).toEqual([old.id]);
      expect(await store.reconcilePage(f.owner.userId, lindera)).toBeUndefined();
      const { DatabaseSync } = await import("node:sqlite");
      const database = new DatabaseSync(f.file);
      try {
        expect(database.prepare("SELECT analyzer FROM personal_memory_chunks WHERE memory_id = ?").all(old.id)).toEqual([{ analyzer: lindera.id }]);
      } finally { database.close(); }
      expect(await ids("設定を見直したい")).toEqual([old.id]);
    } finally { f.close(); }
  });
  it("relaxes the Worker analyzer's all-terms match when a sentence matches nothing", async () => {
    const f = await fixture();
    try {
      const intl = applicationAnalyzer(createIntlSearchTokenizer());
      const memory = new DahliaMemory(f.memory.stores, f.sync, undefined, intl);
      const budget = f.note("2027年度予算は500万円");
      const both = f.note("2027年の予算は未定");
      await memory.save(f.owner, budget); await memory.save(f.owner, both); await memory.save(f.owner, f.note("昼食の注文"));
      const ids = async (query: string) => (await memory.search(f.owner, { scope: "personal", query }, signal)).results[0]!.items.map((item) => item.id);
      // Every term matches only the second memory, so no relaxation happens.
      expect(await ids("2027年の予算")).toEqual([both.id]);
      // No memory contains every word of the question; any-term matching still ranks the budget memories first.
      expect((await ids("2027年の予算はいくら？")).slice(0, 2).toSorted()).toEqual([budget.id, both.id].toSorted());
    } finally { f.close(); }
  });

  it.each(["workspace", "auto"] as const)("withholds recall results when Workspace access is revoked during the scan (%s)", async (scope) => {
    const f = await fixture();
    try {
      await f.memory.save(f.owner, { ...f.note("Shared budget plan"), scope: "workspace", workspaceId: f.workspaceId, explicit: true });
      await f.memory.save(f.owner, f.note("Private budget note"));
      f.generate.mockResolvedValue({ target: "both", reason: "either" });
      const getWorkspace = vi.spyOn(f.sync, "getWorkspace");
      // Revoke once the Workspace scan has gathered matches (the last scan in auto); they must not be published.
      const store = f.memory.stores.workspace;
      const recall = store.recall.bind(store);
      vi.spyOn(store, "recall").mockImplementation(async (...args) => {
        const matches = await recall(...args);
        expect(matches).not.toHaveLength(0);
        getWorkspace.mockResolvedValue(null);
        return matches;
      });
      await expect(f.memory.search(f.owner, { scope, workspaceId: f.workspaceId, query: "budget" }, signal)).rejects.toMatchObject({ status: 404, code: "workspace_not_found" });
      getWorkspace.mockRestore();
      // With access intact the same recall publishes both scopes.
      expect((await f.memory.search(f.owner, { scope, workspaceId: f.workspaceId, query: "budget" }, signal)).results.flatMap((r) => r.items)).not.toHaveLength(0);
    } finally { f.close(); }
  });
  it("shares canonical personal notes across clients, enforces revisions and protects human edits", async () => {
    const f = await fixture();
    try {
      const memory = new DahliaMemory(f.memory.stores, f.sync);
      const input = f.note("Prefer concise answers 100% of the time");
      const impersonated = { ...f.owner, impersonated: true };
      await expect(memory.save(impersonated, input)).rejects.toMatchObject({ code: "impersonation_read_only" });
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
      const result = await memory.search(f.owner, { scope: "personal", workspaceId: f.workspaceId, query: "Human" }, signal);
      expect(result.searchedScopes).toEqual([{ scope: "personal" }]);
      expect(result.results[0]).not.toHaveProperty("workspaceId");
      expect(result.results[0]!.items).toMatchObject([{ content: "Human correction", revision: 2, protected: true }]);
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
      const save = (value: typeof input, actor: "human" | "agent") => store.saveNote(f.owner.userId, scopeId, value, actor, false);
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
      const result = await f.memory.search(f.owner, { scope: "auto", workspaceId: f.workspaceId, query: "question" }, signal);
      expect(result.searchedScopes.map((s) => s.scope)).toEqual(["personal", "workspace"]);
      expect((await f.memory.search(f.owner, { scope: "auto", query: "question" }, signal)).searchedScopes).toEqual([{ scope: "personal" }]);
      f.generate.mockResolvedValue({ target: "workspace", reason: "team_decision" });
      const workspaceOnly = await f.memory.search(f.owner, { scope: "auto", workspaceId: f.workspaceId, query: "decision" }, signal);
      expect(workspaceOnly.searchedScopes).toEqual([{ scope: "workspace", workspaceId: f.workspaceId }]);
      expect(workspaceOnly.results).toMatchObject([{ scope: "workspace", items: [{ content: "Team decision" }] }]);
      await expect(f.memory.save(f.stranger, { ...input, scope: "workspace", explicit: true })).rejects.toMatchObject({ status: 404 });
      const calls = f.generate.mock.calls.length;
      await f.memory.list(f.owner, { scope: "personal" });
      await f.memory.save(f.owner, f.note("Explicit personal"));
      expect(f.generate.mock.calls).toHaveLength(calls);
      await expect(f.memory.save(f.owner, { ...input, revision: 1 })).rejects.toMatchObject({ code: "memory_update_scope_required" });
    } finally { f.close(); }
  });
  it("requires dedicated scopes for MCP and shares the same tools with the internal agent", async () => {
    const f = await fixture();
    try {
      const workingMemory = { settings: async () => ({ revision: 0, automatic: true, capacityReached: false, manual: "A private note", learned: "" }),
        editSettings: async (_identity: unknown, input: { content?: string }) => ({ revision: 1, automatic: true, capacityReached: false, manual: input.content ?? "", learned: "" }) };
      const handler = createServerMcpHandler(f.config, f.sync, undefined, undefined, f.memory, workingMemory as never);
      const list = async (scopes: string[]) => {
        const response = await handler.fetch(new Request("http://localhost:5173/mcp", { method: "POST", headers: { "Mcp-Method": "tools/list", "MCP-Protocol-Version": "2026-07-28", "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list", params: { _meta: { "io.modelcontextprotocol/clientCapabilities": {}, "io.modelcontextprotocol/clientInfo": { name: "test", version: "1" }, "io.modelcontextprotocol/protocolVersion": "2026-07-28" } } }) }), { authInfo: { token: "test", clientId: "test", scopes, extra: { identity: f.owner } } });
        return response.text();
      };
      expect(await list(["mcp"])).not.toContain('"save_memory"');
      expect(await list(["mcp"])).not.toContain('"list_memories"');
      const read = await list([MEMORY_READ_SCOPE]); expect(read).toContain('"list_memories"'); expect(read).toContain('"get_working_memory"');
      expect(read).not.toContain('"save_memory"'); expect(read).not.toContain('"update_working_memory"');
      const write = await list([MEMORY_WRITE_SCOPE]);
      expect(write).toContain('"save_memory"');
      for (const value of [read, write]) for (const removed of ["reflect_memory", "list_knowledge_pages", "get_knowledge_page", "recall_workspace_memory"]) expect(value).not.toContain(`"${removed}"`);
      expect(write).toContain('"update_working_memory"');
      const listed = JSON.parse(write) as { result: { tools: Array<{ name: string; inputSchema: { type: string; oneOf: Array<{ properties: Record<string, unknown> }> } }> } };
      const editSchema = listed.result.tools.find((tool) => tool.name === "update_working_memory")!.inputSchema;
      expect(editSchema.type).toBe("object");
      expect(editSchema.oneOf).toHaveLength(2);
      expect(editSchema.oneOf[0]?.properties).toHaveProperty("content");
      expect(editSchema.oneOf[0]?.properties).not.toHaveProperty("automatic");
      expect(editSchema.oneOf[1]?.properties).toHaveProperty("automatic");
      expect(editSchema.oneOf[1]?.properties).not.toHaveProperty("content");
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
      const extra = await call([MEMORY_WRITE_SCOPE], "update_working_memory", { section: "settings", automatic: false, content: "leftover", revision: 1, explicit: true });
      expect(extra.error ?? extra.result?.isError).toBeTruthy();
      expect((await call([MEMORY_WRITE_SCOPE], "update_working_memory", { section: "settings", automatic: false, revision: 1, explicit: true })).result?.isError).not.toBe(true);
      expect((await call([MEMORY_READ_SCOPE], "save_memory", wireNote)).error).toBeDefined();
      const text = (value: Awaited<ReturnType<typeof call>>) => JSON.parse(value.result!.content[0]!.text) as z.infer<typeof memoryResultSchema>;
      // External client lifecycle: write, read back, recall, update with revision, consolidate (save merged, delete originals).
      expect(text(await call([MEMORY_WRITE_SCOPE], "save_memory", wireNote))).toMatchObject({ saved: true, memory: { id: wireNote.id, revision: 1, protected: false } });
      expect(text(await call([MEMORY_READ_SCOPE], "get_memory", { scope: "personal", id: wireNote.id }))).toMatchObject({ memory: { content: "From remote MCP" } });
      expect(text(await call([MEMORY_READ_SCOPE], "recall_memory", { scope: "personal", query: "remote" })).results![0]!.items).toMatchObject([{ id: wireNote.id }]);
      expect(text(await call([MEMORY_WRITE_SCOPE], "save_memory", { ...wireNote, revision: 1, content: "From remote MCP, updated" }))).toMatchObject({ memory: { revision: 2 } });
      expect((await call([MEMORY_WRITE_SCOPE], "save_memory", { ...wireNote, revision: 1, content: "Stale" })).result).toMatchObject({ isError: true, content: [{ text: "memory_revision_conflict" }] });
      const expired = await call([MEMORY_WRITE_SCOPE], "delete_memory", { scope: "personal", id: wireNote.id, revision: 2, explicit: true }, 1);
      expect(expired.error ?? expired.result?.isError).toBeTruthy();
      expect((await call([MEMORY_READ_SCOPE], "delete_memory", { scope: "personal", id: wireNote.id, revision: 2, explicit: true })).error).toBeDefined();
      const merged = f.note("Merged remote lesson");
      expect(text(await call([MEMORY_WRITE_SCOPE], "save_memory", { ...merged, explicit: true }))).toMatchObject({ saved: true });
      expect(text(await call([MEMORY_WRITE_SCOPE], "delete_memory", { scope: "personal", id: wireNote.id, revision: 2, explicit: true }))).toMatchObject({ deleted: true });
      expect(text(await call([MEMORY_READ_SCOPE], "list_memories", { scope: "personal" })).items!.map((item) => item.content)).toEqual(["Merged remote lesson"]);
      await expect(f.memory.get(f.owner, wireNote)).rejects.toMatchObject({ code: "memory_not_found" });
      await f.memory.delete(f.owner, { ...merged, revision: 1, explicit: true });
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
    for (const extra of [{ projectId: encodeId("project", uuidV7()) }, { depth: "deep" }]) {
      expect(memorySaveSchema.safeParse({ ...input, id: encodeId("sharedMemory", uuidV7()), ...extra }).success).toBe(false);
    }
    for (const id of ["smem_invalid", encodeId("meeting", uuidV7()),
      encodeId("sharedMemory", "00000000-0000-4000-8000-000000000000"),
      encodeId("sharedMemory", "00000000-0000-7000-0000-000000000000")]) {
      expect(memorySaveSchema.safeParse({ ...input, id }).success).toBe(false);
    }
  });
  it.each(["node", "worker"])("exposes canonical Web memory (%s)", async (runtime) => {
    const f = await fixture();
    try {
      const application = createApp({ config: f.config, authStore: f.app });
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
        const edit = { content: "Edited on the Web", revision: 1, explicit: true };
        expect((await request(`/notes/${input.id}`, "PATCH", edit, f.owner.email, workspaceId)).status).toBe(200);
        expect((await request(`/notes/${input.id}`, "PATCH", { ...edit, content: "Stale update" }, f.owner.email, workspaceId)).status).toBe(409);
        expect((await request(`/notes/${input.id}`, "PATCH", { ...edit, revision: 0 }, f.owner.email, workspaceId)).status).toBe(400);
        expect((await request(`/notes/${input.id}?revision=2`, "DELETE", undefined, f.owner.email, workspaceId)).status).toBe(400);
        expect((await request(`/notes/${input.id}?revision=9007199254740992&explicit=true`, "DELETE", undefined, f.owner.email, workspaceId)).status).toBe(400);
        expect((await request(`/notes/${input.id}?revision=2&explicit=true`, "DELETE", undefined, f.owner.email, workspaceId)).status).toBe(200);
        if (workspaceId) {
          expect((await request("/notes", "POST", save, f.owner.email, workspaceId)).status).toBe(200);
          expect((await request("", "DELETE", undefined, f.stranger.email, workspaceId)).status).toBe(404);
          expect(await (await request("", "DELETE", undefined, f.owner.email, workspaceId)).json()).toEqual({ deleted: true });
          expect(await (await request("/notes", "GET", undefined, f.owner.email, workspaceId)).json()).toMatchObject({ items: [] });
        }
        expect((await request("/notes", "POST", { ...save, scope: "personal" }, f.owner.email, workspaceId)).status).toBe(400);
        expect((await request("/notes?scope=personal", "GET", undefined, f.owner.email, workspaceId)).status).toBe(400);
        for (const removed of ["/analysis/status", "/reflect", "/pages"]) expect((await request(removed, removed === "/reflect" ? "POST" : "GET", removed === "/reflect" ? { query: "x" } : undefined, f.owner.email, workspaceId)).status).toBe(404);
        expect((await request("/save", "POST", save, f.owner.email, workspaceId)).status).toBe(404);
        expect((await request("/notes", "PUT", save, f.owner.email, workspaceId)).status).toBe(405);
      }
      expect(await (await request("/recall", "POST", { query: "memory" })).json()).toMatchObject({ results: [{ scope: "personal", items: [] }] });
      expect((await request("/recall", "POST", { query: "memory", projectId: encodeId("project", uuidV7()) })).status).toBe(400);
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

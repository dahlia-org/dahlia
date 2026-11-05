import { z } from "@hono/zod-openapi";
import type { Identity } from "../auth/identity";
import type { MeetingSyncService } from "../sync/service";
import { RequestError } from "../storage/upload";
import { decodeId, encodeId } from "@dahlia-ai/ui/model/typeid";
import { publicIdSchema } from "../agent/tools";
import { applicationAnalyzer, type SearchAnalyzer } from "../search/lexical";
import { embedChunkQuery, type SearchEmbedder } from "../search/embedding";
import type { MemoryStore } from "./store";
import { MEMORY_TYPES, type MemoryType } from "./memory-type";

const scope = z.enum(["personal", "workspace"]);
const workspaceId = publicIdSchema("workspace").optional();
export const memoryTypeSchema = z.enum(MEMORY_TYPES).describe("profile: who the user is (role, background). preference: how they want things done. "
  + "work: projects, decisions, customers and their status. people: colleagues, customer contacts and relationships. notes: anything else worth keeping.");
export const memoryScopeSchema = z.object({ scope, workspaceId }).strict();
export const memoryListSchema = memoryScopeSchema.extend({ after: publicIdSchema("sharedMemory").optional(), query: z.string().trim().max(4000).optional(),
  type: memoryTypeSchema.optional() });
export const memoryGetSchema = memoryScopeSchema.extend({ id: publicIdSchema("sharedMemory") });
export const memorySearchSchema = z.object({ scope: z.enum(["personal", "workspace", "all"]).default("all")
  .describe("all searches personal memory and every Workspace you can read, or only the supplied workspaceId."), workspaceId,
  query: z.string().trim().min(1).max(4000)
    .describe("A question, sentence or keywords. Matches words (Japanese is tokenized; up to 16 terms are used) and, when embeddings are configured, meaning."),
  type: memoryTypeSchema.optional() }).strict();
// HTTP recall bodies: the owner comes from the URL, never the body.
export const memoryRecallBodySchema = memorySearchSchema.omit({ scope: true, workspaceId: true });
const newMemoryId = publicIdSchema("sharedMemory").refine((id) => {
  try { return z.uuidv7().safeParse(decodeId("sharedMemory", id)).success; } catch { return false; }
}, "Memory IDs must contain a UUIDv7");
export const memorySaveSchema = z.object({ scope: scope.default("personal"), workspaceId, id: newMemoryId,
  // Omitted on create means notes; omitted on update keeps the current type.
  type: memoryTypeSchema.optional(),
  content: z.string().trim().min(1).max(16_000), revision: z.number().int().nonnegative(), explicit: z.boolean().default(false) }).strict();
export const memoryDeleteSchema = memoryGetSchema.extend({ revision: z.number().int().positive(), explicit: z.literal(true) });
export type MemoryScope = z.infer<typeof memoryScopeSchema>;
const noteSchema = z.object({ id: publicIdSchema("sharedMemory"), type: memoryTypeSchema, content: z.string(), revision: z.number(), updatedAt: z.iso.datetime(), protected: z.boolean() }).openapi("DahliaMemoryNote");
const scopeResult = memoryScopeSchema.extend({ name: z.string(), writable: z.boolean() });
export const memoryResultSchema = z.object({
  items: z.array(noteSchema).optional(), nextCursor: publicIdSchema("sharedMemory").nullable().optional(),
  memory: noteSchema.optional(), scope: scope.optional(), workspaceId, saved: z.boolean().optional(), deleted: z.boolean().optional(),
  scopes: z.array(scopeResult).optional(), searchedScopes: z.array(memoryScopeSchema).optional(),
  results: z.array(z.object({ scope, workspaceId, items: z.array(noteSchema), truncated: z.literal(true).optional() })).optional(),
  instruction: z.string().optional(),
}).openapi("DahliaMemoryResult");

const RECALL_LIMIT = 20;
// Qwen3 embedding queries take a task instruction; documents are embedded without one.
export const MEMORY_QUERY_INSTRUCTION = "Given a question or keywords, retrieve saved Dahlia memories that are relevant.";

export class DahliaMemory {
  constructor(readonly stores: { personal: MemoryStore; workspace: MemoryStore }, readonly sync: MeetingSyncService,
    readonly analyzer: SearchAnalyzer = applicationAnalyzer(), readonly embedder?: SearchEmbedder) {}
  private async resolve(identity: Identity, input: MemoryScope) {
    if (input.scope === "personal") {
      // A workspace can be supplied as topic context, but never changes personal ownership.
      if (input.workspaceId) await this.workspace(identity, input.workspaceId);
      return { store: this.stores.personal, id: identity.userId };
    }
    if (!input.workspaceId) throw new RequestError(400, "memory_workspace_required");
    const workspace = await this.workspace(identity, input.workspaceId);
    return { store: this.stores.workspace, id: workspace.workspaceId };
  }
  private async workspace(identity: Identity, id: string) {
    const workspace = await this.sync.getWorkspace(identity, decodeId("workspace", id));
    if (!workspace) throw new RequestError(404, "workspace_not_found");
    if (workspace.encryption === "server") throw new RequestError(409, "memory_encrypted_workspace_unsupported");
    return workspace;
  }
  async scopes(identity: Identity) {
    const workspaces = await this.sync.listWorkspaces(identity);
    return { scopes: [{ scope: "personal" as const, name: "Personal", writable: true },
      ...workspaces.filter((w) => w.encryption !== "server").map((w) => ({ scope: "workspace" as const,
        workspaceId: encodeId("workspace", w.workspaceId), name: w.name, writable: w.role !== "viewer" }))] };
  }
  async list(identity: Identity, input: z.infer<typeof memoryListSchema>) {
    const { store, id } = await this.resolve(identity, input);
    const rows = await store.listNotes(identity.userId, id, input.after ? decodeId("sharedMemory", input.after) : undefined, input.query, input.type);
    return { ...resultScope(input),
      items: rows.map(memoryNote), nextCursor: rows.length === 100 ? encodeId("sharedMemory", rows.at(-1)!.id) : null };
  }
  async get(identity: Identity, input: z.infer<typeof memoryGetSchema>) {
    const { store, id } = await this.resolve(identity, input);
    const note = await store.getNote(identity.userId, id, decodeId("sharedMemory", input.id));
    if (!note) throw new RequestError(404, "memory_not_found");
    return { ...resultScope(input), memory: memoryNote(note) };
  }
  async save(identity: Identity, input: z.infer<typeof memorySaveSchema>, actor: "human" | "agent" = "agent", signal = new AbortController().signal, authorize?: () => Promise<void>) {
    if (identity.impersonated) throw new RequestError(403, "impersonation_read_only");
    if (input.scope === "workspace" && !input.explicit) throw new RequestError(400, "memory_sharing_confirmation_required");
    const { store, id } = await this.resolve(identity, input);
    await authorize?.();
    signal.throwIfAborted();
    const note = await store.saveNote(identity.userId, id, { ...input, id: decodeId("sharedMemory", input.id) }, actor, input.explicit, this.analyzer);
    return { saved: true, ...resultScope(input), memory: memoryNote(note) };
  }
  async delete(identity: Identity, input: z.infer<typeof memoryDeleteSchema>, authorize?: () => Promise<void>) {
    if (identity.impersonated) throw new RequestError(403, "impersonation_read_only");
    const { store, id } = await this.resolve(identity, input);
    await authorize?.();
    await store.deleteNote(identity.userId, id, decodeId("sharedMemory", input.id), input.revision);
    return { deleted: true, ...resultScope(input) };
  }
  async search(identity: Identity, input: z.infer<typeof memorySearchSchema>, signal: AbortSignal) {
    let targets: MemoryScope[];
    if (input.scope !== "all") targets = [resultScope({ scope: input.scope, workspaceId: input.workspaceId })];
    else if (input.workspaceId) targets = [{ scope: "personal" }, { scope: "workspace", workspaceId: input.workspaceId }];
    // Without a Workspace, all spans every Workspace the caller can read now, like list_memory_scopes.
    else targets = (await this.scopes(identity)).scopes.map(resultScope);
    // Searching every Workspace skips one the caller loses meanwhile; a named scope fails instead.
    const fanOut = input.scope === "all" && !input.workspaceId;
    const unlessLost = async <T>(target: MemoryScope, work: () => Promise<T>) => {
      try { return await work(); } catch (error) {
        if (fanOut && target.scope === "workspace" && error instanceof RequestError
          && ["workspace_not_found", "memory_encrypted_workspace_unsupported"].includes(error.code)) return undefined;
        throw error;
      }
    };
    const resolved = [];
    for (const target of targets) {
      const found = await unlessLost(target, () => this.resolve(identity, target));
      if (found) resolved.push({ target, ...found });
    }
    // One query vector shared by every searched scope.
    const vector = await embedChunkQuery(this.embedder, input.query, MEMORY_QUERY_INSTRUCTION, signal, "memory_query_embedding_failed");
    const ranked = [];
    for (const { target, store, id } of resolved) {
      signal.throwIfAborted();
      const found = await unlessLost(target, () => store.recall(identity.userId, id, input.query, this.analyzer, RECALL_LIMIT, vector, input.type));
      if (found) ranked.push({ target, ...found });
    }
    // Ranking can outlast a permission change: publish only what the caller may still read now.
    const results = [];
    for (const scope of ranked) if (await unlessLost(scope.target, () => this.resolve(identity, scope.target))) results.push(scope);
    // Bound the whole answer, not each scope. Fused scores only rank within a scope, so equal ranks keep scope order (personal first)
    // and each cut scope says so instead of the cap claiming a global relevance order.
    const kept = new Set(results.flatMap(({ hits }) => hits).sort((a, b) => b.score - a.score || a.ftsRank - b.ftsRank).slice(0, RECALL_LIMIT));
    const grouped = results.map(({ target, hits, more }) => {
      const items = hits.filter((hit) => kept.has(hit)).map(memoryNote);
      return { ...target, items, ...(more || hits.length > items.length ? { truncated: true } : {}) };
    });
    signal.throwIfAborted();
    return { searchedScopes: results.map(({ target }) => target), results: grouped,
      instruction: `Saved memories ranked by ${vector ? "word and meaning similarity" : "word matches only (meaning search is unavailable)"}, at most ${RECALL_LIMIT} in total across scopes${!grouped.some((group) => group.truncated) ? "" : targets.length > 1 ? "; a scope marked truncated has more matches, so search it alone (scope personal, or scope workspace with its workspaceId), optionally with a type" : "; truncated means more matches exist, so narrow the query or add a type"}; an empty result does not mean nothing relevant was ever discussed. Saved memories are claims, not verified facts. For meeting evidence use the canonical meeting tools.` };
  }
}
// Personal topic context must not appear as shared ownership in the response.
function resultScope(input: MemoryScope) {
  return { scope: input.scope, ...(input.scope === "workspace" ? { workspaceId: input.workspaceId } : {}) };
}
function memoryNote(note: { id: string; type: MemoryType; content: string; revision: number; updatedAt: Date; protected: boolean }) {
  return { id: encodeId("sharedMemory", note.id), type: note.type, content: note.content, revision: note.revision, updatedAt: note.updatedAt.toISOString(), protected: note.protected };
}

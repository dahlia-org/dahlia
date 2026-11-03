import { z } from "@hono/zod-openapi";
import type { Identity } from "../auth/identity";
import type { MemoryGenerator } from "../agent/context-service";
import type { MeetingSyncService } from "../sync/service";
import { RequestError } from "../storage/upload";
import { decodeId, encodeId } from "@dahlia-ai/ui/model/typeid";
import { publicIdSchema } from "../agent/tools";
import { SEARCH_QUERY_MAX_TOKENS } from "../search/tokenizer";
import { normalizeMemoryText, type MemoryStore } from "./store";
import { routeMemory } from "./router";

const scope = z.enum(["personal", "workspace"]);
const workspaceId = publicIdSchema("workspace").optional();
export const memoryScopeSchema = z.object({ scope, workspaceId }).strict();
export const memoryListSchema = memoryScopeSchema.extend({ after: publicIdSchema("sharedMemory").optional(), query: z.string().trim().max(4000).optional() });
export const memoryGetSchema = memoryScopeSchema.extend({ id: publicIdSchema("sharedMemory") });
const memoryTargetSchema = z.object({ scope: z.enum(["personal", "workspace", "auto"]).default("auto"), workspaceId }).strict();
export const memorySearchSchema = memoryTargetSchema.extend({ query: z.string().trim().min(1).max(4000)
  .describe("Space-separated keywords, not a sentence; the first 16 distinct keywords are used. Each matches saved memories that contain it, ignoring case and full/half width.") });
// HTTP recall bodies: the owner comes from the URL, never the body.
export const memoryRecallBodySchema = memorySearchSchema.omit({ scope: true, workspaceId: true });
const newMemoryId = publicIdSchema("sharedMemory").refine((id) => {
  try { return z.uuidv7().safeParse(decodeId("sharedMemory", id)).success; } catch { return false; }
}, "Memory IDs must contain a UUIDv7");
export const memorySaveSchema = memoryTargetSchema.extend({ id: newMemoryId,
  content: z.string().trim().min(1).max(16_000), revision: z.number().int().nonnegative(), explicit: z.boolean().default(false) });
export const memoryDeleteSchema = memoryGetSchema.extend({ revision: z.number().int().positive(), explicit: z.literal(true) });
export type MemoryScope = z.infer<typeof memoryScopeSchema>;
const noteSchema = z.object({ id: publicIdSchema("sharedMemory"), content: z.string(), revision: z.number(), updatedAt: z.iso.datetime(), protected: z.boolean() }).openapi("DahliaMemoryNote");
const scopeResult = memoryScopeSchema.extend({ name: z.string(), writable: z.boolean() });
export const memoryResultSchema = z.object({
  items: z.array(noteSchema).optional(), nextCursor: publicIdSchema("sharedMemory").nullable().optional(),
  memory: noteSchema.optional(), scope: scope.optional(), workspaceId, saved: z.boolean().optional(), deleted: z.boolean().optional(),
  suggestedScope: z.enum(["personal", "workspace", "both", "uncertain"]).optional(), reason: z.string().optional(),
  scopes: z.array(scopeResult).optional(), searchedScopes: z.array(memoryScopeSchema).optional(),
  results: z.array(z.object({ scope, workspaceId, items: z.array(noteSchema) })).optional(),
  instruction: z.string().optional(),
}).openapi("DahliaMemoryResult");

const RECALL_LIMIT = 20;
// shortcut: substring keyword match, no embeddings; add a vector index when saved memories outgrow keyword recall.
// The caller chooses the keywords: parsing a sentence into content words cannot be done reliably here.
export function recallTerms(query: string) {
  return [...new Set(normalizeMemoryText(query).split(/\s+/u).filter(Boolean))].slice(0, SEARCH_QUERY_MAX_TOKENS);
}
export function rankNotes(matches: Awaited<ReturnType<MemoryStore["searchNotes"]>>) {
  // UUIDv7 IDs break updatedAt ties by creation order, keeping the ranking deterministic.
  return matches.toSorted((a, b) => b.terms.length - a.terms.length || b.note.updatedAt.getTime() - a.note.updatedAt.getTime()
    || (a.note.id < b.note.id ? 1 : a.note.id > b.note.id ? -1 : 0)).map(({ note }) => note);
}

export class DahliaMemory {
  constructor(readonly stores: { personal: MemoryStore; workspace: MemoryStore }, readonly sync: MeetingSyncService, readonly generate?: MemoryGenerator) {}
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
    const rows = await store.listNotes(identity.userId, id, input.after ? decodeId("sharedMemory", input.after) : undefined, input.query);
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
    let target = input.scope;
    if (target === "auto") {
      // Existing records must always be updated in an explicit, fixed scope.
      if (input.revision > 0) throw new RequestError(400, "memory_update_scope_required");
      const workspace = input.workspaceId ? await this.workspace(identity, input.workspaceId) : undefined;
      const route = await routeMemory(this.generate, identity, "save", input.content,
        workspace ? { id: input.workspaceId!, name: workspace.name } : undefined, signal);
      if (route.target === "uncertain" || route.target === "both" || (route.target === "workspace" && !input.explicit)) {
        return { saved: false, suggestedScope: route.target, reason: route.reason, workspaceId: input.workspaceId };
      }
      target = route.target;
    }
    if (target === "workspace" && !input.explicit) throw new RequestError(400, "memory_sharing_confirmation_required");
    const { store, id } = await this.resolve(identity, { ...input, scope: target });
    await authorize?.();
    signal.throwIfAborted();
    const note = await store.saveNote(identity.userId, id, { ...input, id: decodeId("sharedMemory", input.id) }, actor, input.explicit);
    return { saved: true, ...resultScope({ scope: target, workspaceId: input.workspaceId }), memory: memoryNote(note) };
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
    if (input.scope !== "auto") targets = [resultScope({ scope: input.scope, workspaceId: input.workspaceId })];
    else {
      const workspace = input.workspaceId ? await this.workspace(identity, input.workspaceId) : undefined;
      const route = await routeMemory(this.generate, identity, "read", input.query,
        workspace ? { id: input.workspaceId!, name: workspace.name } : undefined, signal);
      targets = [];
      if (route.target !== "workspace" || !workspace) targets.push({ scope: "personal" });
      if (workspace && route.target !== "personal") targets.push({ scope: "workspace", workspaceId: input.workspaceId });
    }
    const terms = recallTerms(input.query);
    const results = [];
    for (const target of targets) {
      signal.throwIfAborted();
      const { store, id } = await this.resolve(identity, target);
      results.push({ ...target, items: rankNotes(await store.searchNotes(identity.userId, id, terms)).slice(0, RECALL_LIMIT).map(memoryNote) });
    }
    return { searchedScopes: targets, results,
      instruction: "Saved memories ranked by the number of keywords they contain, at most 20 per scope; an empty result does not mean nothing relevant was ever discussed. Saved memories are claims, not verified facts. For meeting evidence use the canonical meeting tools." };
  }
}
// Personal topic context must not appear as shared ownership in the response.
function resultScope(input: MemoryScope) {
  return { scope: input.scope, ...(input.scope === "workspace" ? { workspaceId: input.workspaceId } : {}) };
}
function memoryNote(note: { id: string; content: string; revision: number; updatedAt: Date; protected: boolean }) {
  return { id: encodeId("sharedMemory", note.id), content: note.content, revision: note.revision, updatedAt: note.updatedAt.toISOString(), protected: note.protected };
}

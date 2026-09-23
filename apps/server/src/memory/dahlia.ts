import { z } from "@hono/zod-openapi";
import type { Identity } from "../auth/identity";
import type { MemoryGenerator } from "../agent/context-service";
import type { MeetingSyncService } from "../sync/service";
import { RequestError } from "../storage/upload";
import { decodeId, encodeId } from "../typeid";
import { publicIdSchema } from "../agent/tools";
import type { MemoryStore } from "./store";
import type { WorkspaceMemoryService } from "./service";
import { HindsightError } from "./hindsight";
import { routeMemory } from "./router";

const scope = z.enum(["personal", "workspace"]);
const workspaceId = publicIdSchema("workspace").optional();
export const memoryScopeSchema = z.object({ scope, workspaceId }).strict();
export const memoryListSchema = memoryScopeSchema.extend({ after: publicIdSchema("sharedMemory").optional(), query: z.string().trim().max(4000).optional() });
export const memoryGetSchema = memoryScopeSchema.extend({ id: publicIdSchema("sharedMemory") });
export const memorySearchSchema = z.object({ scope: z.enum(["personal", "workspace", "auto"]).default("auto"), workspaceId,
  query: z.string().trim().min(1).max(4000) }).strict();
const newMemoryId = publicIdSchema("sharedMemory").refine((id) => {
  try { return z.uuidv7().safeParse(decodeId("sharedMemory", id)).success; } catch { return false; }
}, "Memory IDs must contain a UUIDv7");
export const memorySaveSchema = memorySearchSchema.omit({ query: true }).extend({ id: newMemoryId,
  content: z.string().trim().min(1).max(16_000), revision: z.number().int().nonnegative(), explicit: z.boolean().default(false) });
export const memoryDeleteSchema = memoryGetSchema.extend({ revision: z.number().int().positive(), explicit: z.literal(true) });
export const memoryConfigureSchema = memoryScopeSchema.extend({ enabled: z.boolean() });
export type MemoryScope = z.infer<typeof memoryScopeSchema>;
const noteSchema = z.object({ id: publicIdSchema("sharedMemory"), content: z.string(), revision: z.number(), updatedAt: z.iso.datetime(), protected: z.boolean() }).openapi("DahliaMemoryNote");
const scopeResult = memoryScopeSchema.extend({ name: z.string(), writable: z.boolean() });
export const memoryResultSchema = z.object({
  items: z.array(noteSchema).optional(), nextCursor: publicIdSchema("sharedMemory").nullable().optional(),
  memory: noteSchema.optional(), scope: scope.optional(), workspaceId, saved: z.boolean().optional(), deleted: z.boolean().optional(),
  suggestedScope: z.enum(["personal", "workspace", "both", "uncertain"]).optional(), reason: z.string().optional(),
  scopes: z.array(scopeResult).optional(), searchedScopes: z.array(memoryScopeSchema).optional(),
  results: z.array(z.object({ scope, workspaceId, result: z.object({
    sources: z.array(z.object({ kind: z.string(), id: z.string(), revision: z.string(), meeting_id: z.string().nullable(), workspace_id: z.string().nullable(), scope, canonicalExcerpt: z.string(), truncated: z.boolean() })).optional(),
    hypothesis: z.string().nullable().optional(), coverage: z.string().optional(), skippedCount: z.number().optional(),
    unavailable: z.boolean().optional(), code: z.string().optional(), instruction: z.string().optional(),
    canonical: z.object({ scope, workspaceId, items: z.array(noteSchema), nextCursor: z.string().nullable() }).optional(),
  }) })).optional(),
  enabled: z.boolean().optional(), status: z.string().optional(), errorCode: z.string().nullable().optional(),
  attempts: z.number().optional(), skippedCount: z.number().optional(), skippedSources: z.array(z.object({ source: z.string(), code: z.string() })).optional(),
}).openapi("DahliaMemoryResult");

export class DahliaMemory {
  constructor(readonly stores: { personal: MemoryStore; workspace: MemoryStore }, readonly sync: MeetingSyncService,
    readonly engines: { personal?: WorkspaceMemoryService; workspace?: WorkspaceMemoryService }, readonly generate?: MemoryGenerator) {}
  private async resolve(identity: Identity, input: MemoryScope) {
    if (input.scope === "personal") {
      // A workspace can be supplied as topic context, but never changes personal ownership.
      if (input.workspaceId) await this.workspace(identity, input.workspaceId);
      return { store: this.stores.personal, id: identity.userId, engine: this.engines.personal };
    }
    if (!input.workspaceId) throw new RequestError(400, "memory_workspace_required");
    const workspace = await this.workspace(identity, input.workspaceId);
    return { store: this.stores.workspace, id: workspace.workspaceId, engine: this.engines.workspace };
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
    const note = await store.saveNote(identity.userId, id, { ...input, id: decodeId("sharedMemory", input.id) }, actor, input.explicit, true);
    return { saved: true, ...resultScope({ scope: target, workspaceId: input.workspaceId }), memory: memoryNote(note) };
  }
  async delete(identity: Identity, input: z.infer<typeof memoryDeleteSchema>, authorize?: () => Promise<void>) {
    if (identity.impersonated) throw new RequestError(403, "impersonation_read_only");
    const { store, id } = await this.resolve(identity, input);
    await authorize?.();
    await store.deleteNote(identity.userId, id, decodeId("sharedMemory", input.id), input.revision);
    return { deleted: true, ...resultScope(input) };
  }
  async status(identity: Identity, input: MemoryScope) {
    const { store, id, engine } = await this.resolve(identity, input);
    if (engine) return engine.status(identity, id);
    await store.status(identity.userId, id);
    return { enabled: false, status: "unavailable", errorCode: "memory_analysis_unconfigured", attempts: 0, skippedCount: 0, skippedSources: [] };
  }
  async configure(identity: Identity, input: z.infer<typeof memoryConfigureSchema>) {
    if (identity.impersonated) throw new RequestError(403, "impersonation_read_only");
    const { id, engine } = await this.resolve(identity, input);
    if (!engine) throw new RequestError(409, "memory_analysis_unconfigured");
    await engine.configure(identity, id, input.enabled);
    return this.status(identity, input);
  }
  async search(identity: Identity, input: z.infer<typeof memorySearchSchema>, reflect: boolean, signal: AbortSignal) {
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
    const completed = await Promise.all(targets.map(async (target) => {
      const { engine, store, id } = await this.resolve(identity, target);
      const state = await store.status(identity.userId, id);
      try {
        if (!engine) throw new HindsightError("memory_analysis_unconfigured");
        const result = await engine.search(identity, id, input.query, reflect, signal);
        return { target, state, code: undefined, result: { ...result, sources: result.sources.map((source) => ({ ...source,
          id: encodeId(source.kind === "meeting" ? "meeting" : "sharedMemory", source.id) })) } };
      } catch (error) {
        signal.throwIfAborted();
        if (error instanceof RequestError) throw error;
        return { target, state, result: undefined, code: error instanceof HindsightError ? error.code : "memory_unavailable" };
      }
    }));
    const results = [];
    // A slower bank must not extend another bank's source validity or authorization lifetime.
    for (const { target, state, result, code } of completed) {
      signal.throwIfAborted();
      const { store, id } = await this.resolve(identity, target);
      const current = await store.status(identity.userId, id);
      const unchanged = state && current && current.generation === state.generation
        && current.bankId === state.bankId && current.enabled && !current.purge;
      results.push({ ...target, result: result && unchanged ? result : {
        unavailable: true, code: code ?? "memory_source_changed",
        // Read canonical fallback only after all external searches have finished.
        canonical: await this.list(identity, { ...target, query: input.query }),
        instruction: "Analysis is unavailable. These are literal text matches only, not complete semantic recall.",
      } });
    }
    return { searchedScopes: targets, results };
  }
}
// Personal topic context must not appear as shared ownership in the response.
function resultScope(input: MemoryScope) {
  return { scope: input.scope, ...(input.scope === "workspace" ? { workspaceId: input.workspaceId } : {}) };
}
function memoryNote(note: { id: string; content: string; revision: number; updatedAt: Date; protected: boolean }) {
  return { id: encodeId("sharedMemory", note.id), content: note.content, revision: note.revision, updatedAt: note.updatedAt.toISOString(), protected: note.protected };
}

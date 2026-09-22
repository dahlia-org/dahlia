import type { AppConfig } from "../config";
import type { Identity } from "../auth/identity";
import type { MeetingSyncService } from "../sync/service";
import type { MeetingSyncStore } from "../sync/types";
import { RequestError } from "../storage/upload";
import { uuidV7 } from "../id";
import { encodeId } from "../typeid";
import { HindsightClient, HindsightError } from "./hindsight";
import type { MemoryDocument, MemoryProgress } from "./model";
import { contentHash, meetingDocument, noteDocument } from "./sources";
import type { MemoryState, MemoryStore } from "./store";

export class WorkspaceMemoryService {
  readonly client: HindsightClient;
  constructor(config: AppConfig, readonly store: MemoryStore, private readonly sync: MeetingSyncService,
    private readonly syncStore: MeetingSyncStore, transport: typeof fetch = fetch) {
    this.client = new HindsightClient(config.hindsight!, config.databricksWorkspace, transport);
  }
  async status(identity: Identity, workspaceId: string) {
    const state = await this.store.status(identity.userId, workspaceId);
    let status = "paused";
    if (state?.purge) status = "deleting";
    else if (state?.enabled) status = state.indexedGeneration === state.generation ? (state.progress?.skippedCount ? "partial" : "ready") : state.status;
    return { enabled: state?.enabled ?? false, status,
      errorCode: state?.errorCode ?? null, attempts: state?.attempts ?? 0,
      skippedCount: state?.progress?.skippedCount ?? 0, skippedSources: state?.progress?.skippedSources ?? [] };
  }
  configure(identity: Identity, workspaceId: string, enabled: boolean) {
    return this.store.configure(identity.userId, workspaceId, this.client.bank(workspaceId), enabled);
  }
  private async readable(identity: Identity, workspaceId: string) {
    const state = await this.store.status(identity.userId, workspaceId);
    if (!state?.enabled || state.purge || state.generation !== state.indexedGeneration || state.bankId !== this.client.bank(workspaceId)) {
      throw new HindsightError("memory_not_ready");
    }
    return state;
  }
  private async source(identity: Identity, workspaceId: string, documentId: string, signal: AbortSignal) {
    const saved = await this.store.document(workspaceId, documentId);
    if (!saved) return null;
    const document = saved.source.kind === "meeting"
      ? await meetingDocument(this.sync, identity, workspaceId, saved.source.id, signal)
      : await this.store.getNote(identity.userId, workspaceId, saved.source.id).then((note) => note ? noteDocument(note) : null);
    if (!document || document.source.revision !== saved.source.revision) return null;
    return await contentHash(document.content) === saved.contentHash ? document : null;
  }
  async search(identity: Identity, workspaceId: string, query: string, reflect: boolean, signal: AbortSignal) {
    signal = AbortSignal.any([signal, AbortSignal.timeout(30_000)]);
    const state = await this.readable(identity, workspaceId);
    const reflection = reflect ? await this.client.reflect(state.bankId, query, signal) : undefined;
    const facts = await this.client.recall(state.bankId, query, signal);
    const reflectionSources: string[][] = [];
    const reflectionFacts = reflection?.based_on?.memories ?? [];
    if (reflectionFacts.length <= 10) {
      for (const fact of reflectionFacts) reflectionSources.push(fact.id ? await this.client.factDocuments(state.bankId, fact.id, signal) : []);
    }
    const reflectionModels = reflection?.based_on?.mental_models ?? [];
    if (reflectionModels.length <= 3) {
      for (const model of reflectionModels) reflectionSources.push(await this.client.modelDocuments(state.bankId, model.id, signal));
    }
    const ids = [...new Set([...reflectionSources.flat(), ...facts.flatMap((fact) => fact.document_id ? [fact.document_id] : [])])].slice(0, 5);
    const documents: MemoryDocument[] = [];
    for (const id of ids) {
      const document = await this.source(identity, workspaceId, id, signal);
      if (document) documents.push(document);
    }
    const current = await this.readable(identity, workspaceId);
    if (current.generation !== state.generation) throw new HindsightError("memory_source_changed");

    const verified = new Set(documents.map((document) => document.id));
    const referenceCount = reflectionFacts.length + reflectionModels.length;
    const allReferencesVerified = referenceCount > 0
      && reflectionSources.length === referenceCount
      && reflectionSources.every((ids) => ids.length > 0 && ids.every((id) => verified.has(id)));
    const hypothesis = allReferencesVerified ? reflection?.text : undefined;
    return { sources: documents.map((document) => ({
      kind: document.source.kind, id: document.source.id, revision: document.source.revision,
      meeting_id: document.source.kind === "meeting" ? encodeId("meeting", document.source.id) : null,
      workspace_id: encodeId("workspace", workspaceId),
      // Only canonical Dahlia content is evidence. Memory extraction is never returned as a fact.
      canonicalExcerpt: document.content.slice(0, 16_000), truncated: document.content.length > 16_000,
    })), hypothesis: hypothesis ?? null, skippedCount: current.progress?.skippedCount ?? 0,
    instruction: "Cite these Dahlia sources. A transcript proves that a statement was recorded, not that it is objectively true. The hypothesis is an unverified interpretation: check claims against the canonical excerpts and meeting tools. If skippedCount is nonzero, disclose incomplete memory coverage and use canonical tools for the omitted sources. Do not infer counts or trends from retrieval hits." };
  }

  async step(workspaceId: string, signal: AbortSignal) {
    signal = AbortSignal.any([signal, AbortSignal.timeout(90_000)]);
    const job = await this.store.claim(workspaceId);
    if (!job) return;
    try {
      // A durable cleanup row outlives the Workspace and its user grants.
      if (job.purge || !await this.store.exists(workspaceId)) {
        if (job.progress?.operationId) {
          const status = await this.client.operation(job.bankId, job.progress.operationId, signal);
          if (status === "pending" || status === "processing") { await this.store.release(job); return; }
        }
        await this.client.deleteBank(job.bankId, signal);
        await this.store.purged(job);
        return;
      }
      if (!job.enabled) { await this.store.release(job, { availableAt: new Date(Date.now() + 60_000) }); return; }
      if (job.bankId !== this.client.bank(workspaceId)) throw new HindsightError("memory_bank_config_changed");
      const workerUser = await this.store.workerUser(workspaceId);
      if (!workerUser) throw new HindsightError("memory_authorization_changed");
      const identity: Identity = { userId: workerUser, source: "accounts" };
      const workspace = await this.sync.getWorkspace(identity, workspaceId);
      if (!workspace || workspace.role !== "admin" || workspace.encryption === "server") throw new HindsightError("memory_authorization_changed");
      if (job.indexedGeneration === job.generation) { await this.store.release(job, { availableAt: new Date(Date.now() + 60_000) }); return; }
      let progress = job.progress;
      if (progress?.operationId) {
        const status = await this.client.operation(job.bankId, progress.operationId, signal);
        if (status === "pending" || status === "processing") { await this.store.release(job); return; }
        if ((status === "failed" || status === "cancelled") && progress.generation === job.generation) {
          if ((progress.operationAttempts ?? 0) < 3) {
            progress = { ...progress, operationAttempts: (progress.operationAttempts ?? 0) + 1 };
            await this.store.setProgress(job, progress);
            await this.client.retryOperation(job.bankId, progress.operationId!, signal);
            await this.store.release(job, { progress, status: "indexing" });
            return;
          }
          if (progress.modelId) await this.client.deleteModel(job.bankId, progress.modelId, signal);
          this.skip(progress, progress.documentId ?? progress.modelId ?? progress.operationId, "memory_operation_failed");
        }
        if (status === "not_found" && !progress.documentId) {
          // An expired/lost model operation is not proof that its refresh completed.
          progress = null;
        } else if (status === "not_found" && progress.generation === job.generation && progress.documentId) {
          const document = await this.source(identity, workspaceId, progress.documentId, signal);
          if (document) {
            await this.client.retain(job.bankId, document, progress.operationId, signal);
            await this.store.release(job);
            return;
          }
          progress = null;
        } else {
          if (status === "completed" && progress.documentId) await this.store.confirmDocument(workspaceId, progress.documentId, progress.generation);
          progress = { ...progress, operationId: undefined, documentId: undefined, modelId: undefined, operationAttempts: undefined, after: progress.nextAfter ?? progress.after, nextAfter: undefined };
        }
      }
      if (!progress || progress.generation !== job.generation) {
        await this.client.initialize(job.bankId, signal);
        progress = { generation: job.generation, phase: "reset" };
      }
      if (progress.phase === "reset") {
        // ponytail: rebuild derived models on reconciliation; selectively invalidate if this becomes costly.
        const [model] = await this.client.models(job.bankId, signal);
        if (model) await this.client.deleteModel(job.bankId, model.id, signal);
        else progress = { ...progress, phase: "meetings", after: undefined };
      } else if (progress.phase === "meetings") {
        const [createdAt, meetingId] = progress.after?.split(",") ?? [];
        const cursor = progress.after ? { createdAt: new Date(createdAt!), meetingId: meetingId! } : undefined;
        const [meeting] = await this.syncStore.withIdentity(identity, (scoped) => scoped.listMeetings(workspaceId, undefined, 1, undefined,
          cursor));
        if (meeting) {
          const after = `${meeting.createdAt.toISOString()},${meeting.meetingId}`;
          try {
            const document = await meetingDocument(this.sync, identity, workspaceId, meeting.meetingId, signal);
            if (document && await this.submit(job, progress, document, after, signal)) return;
          } catch (error) {
            if (!(error instanceof HindsightError) || error.code !== "memory_source_too_large") throw error;
            this.skip(progress, `meeting-${meeting.meetingId}`, error.code);
          }
          progress.after = after;
        } else { progress = { ...progress, phase: "notes", after: undefined }; }
      } else if (progress.phase === "notes") {
        const [note] = await this.store.listNotes(identity.userId, workspaceId, progress.after);
        if (note) {
          if (await this.submit(job, progress, noteDocument(note), note.id, signal)) return;
          progress.after = note.id;
        } else { progress = { ...progress, phase: "cleanup", after: undefined }; }
      } else if (progress.phase === "cleanup") {
        const [obsolete] = await this.store.obsolete(job);
        if (obsolete) {
          await this.client.deleteDocument(job.bankId, obsolete.documentId, signal);
          await this.store.forgetDocument(workspaceId, obsolete.documentId);
        } else {
          const projectIds = new Set<string>();
          let after: string | undefined;
          for (;;) {
            const rows = await this.store.documents(workspaceId, after);
            rows.forEach((row) => { if (row.source.projectId) projectIds.add(row.source.projectId); });
            if (rows.length < 100) break;
            after = rows.at(-1)!.documentId;
          }
          progress = { ...progress, phase: "models", after: undefined, modelIds: ["workspace", ...projectIds] };
        }
      } else if (progress.modelIds?.length) {
        const [id, ...rest] = progress.modelIds;
        const operationId = await this.client.createModel(job.bankId, id === "workspace" ? null : id!, signal);
        progress = { ...progress, modelIds: rest, operationId, modelId: id === "workspace" ? "workspace-insights" : `project-${id}`, operationAttempts: 0 };
      } else {
        await this.store.release(job, { indexedGeneration: job.generation, status: "ready", progress: progress.skippedCount ? progress : null,
          attempts: 0, errorCode: null, availableAt: new Date(Date.now() + 60_000) });
        return;
      }
      await this.store.release(job, { progress, status: "indexing", attempts: 0, errorCode: null });
    } catch (error) {
      const code = error instanceof HindsightError ? error.code : error instanceof RequestError ? "memory_source_unavailable" : "memory_processing_failed";
      await this.store.release(job, { status: "error", errorCode: code, attempts: job.attempts + 1,
        availableAt: new Date(Date.now() + Math.min(300_000, 5_000 * 2 ** Math.min(job.attempts, 6))) });
    }
  }
  private skip(progress: MemoryProgress, source: string, code: string) {
    progress.skippedCount = (progress.skippedCount ?? 0) + 1;
    // Bound persisted diagnostics; the count still reports all omitted items.
    progress.skippedSources = [...(progress.skippedSources ?? []), { source, code }].slice(0, 20);
  }
  private async submit(job: MemoryState, progress: MemoryProgress, document: MemoryDocument, after: string, signal: AbortSignal) {
    const hash = await contentHash(document.content);
    const previous = await this.store.document(job.workspaceId, document.id);
    if (previous && previous.generation > 0 && previous.contentHash === hash) {
      await this.store.saveDocument(job, document.id, document.source, hash);
      return false;
    }
    const next = { ...progress, operationId: uuidV7(), documentId: document.id, nextAfter: after };
    await this.store.saveDocument(job, document.id, document.source, hash, true);
    await this.store.setProgress(job, next);
    await this.client.retain(job.bankId, document, next.operationId, signal);
    await this.store.release(job, { progress: next, status: "indexing" });
    return true;
  }
}

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
import type { MemoryState, MemoryStore, MemorySourceJob } from "./store";

export class WorkspaceMemoryService {
  readonly client: HindsightClient;
  constructor(config: AppConfig, readonly store: MemoryStore, private readonly sync: MeetingSyncService,
    private readonly syncStore: MeetingSyncStore, transport: typeof fetch = fetch) {
    this.client = new HindsightClient(config.hindsight!, config.databricksWorkspace, transport);
  }
  async status(identity: Identity, scopeId: string) {
    const state = await this.store.status(identity.userId, scopeId);
    const failures = Object.entries(state?.progress?.failures ?? {});
    let status = "paused";
    if (state?.purge) status = "deleting";
    else if (state?.enabled) {
      if (state.reconcile || state.indexedGeneration !== state.generation) status = state.status;
      else status = failures.length ? "partial" : "ready";
    }
    return { enabled: state?.enabled ?? false, status,
      errorCode: state?.errorCode ?? null, attempts: state?.attempts ?? 0,
      skippedCount: failures.length, skippedSources: failures.slice(-20).map(([source, code]) => ({ source, code })) };
  }
  configure(identity: Identity, scopeId: string, enabled: boolean) {
    return this.store.configure(identity.userId, scopeId, this.client.bank(scopeId, this.store.personal), enabled);
  }
  private async readable(identity: Identity, scopeId: string) {
    const state = await this.store.status(identity.userId, scopeId);
    if (!state?.enabled || state.purge || state.bankId !== this.client.bank(scopeId, this.store.personal)) {
      throw new HindsightError("memory_not_ready");
    }
    return state;
  }
  private async source(identity: Identity, scopeId: string, documentId: string, signal: AbortSignal) {
    const saved = await this.store.document(scopeId, documentId);
    if (!saved || saved.generation <= 0 || await this.store.pending(scopeId, documentId)) return null;
    const document = saved.source.kind === "meeting"
      ? await meetingDocument(this.sync, identity, scopeId, saved.source.id, signal)
      : await this.store.getNote(identity.userId, scopeId, saved.source.id).then((note) => note ? noteDocument(note, this.store.personal) : null);
    if (!document || document.source.revision !== saved.source.revision) return null;
    return await contentHash(document.content) === saved.contentHash ? document : null;
  }
  async search(identity: Identity, scopeId: string, query: string, reflect: boolean, signal: AbortSignal) {
    signal = AbortSignal.any([signal, AbortSignal.timeout(30_000)]);
    const state = await this.readable(identity, scopeId);
    const reflection = reflect && !state.reconcile && state.generation === state.indexedGeneration ? await this.client.reflect(state.bankId, query, signal) : undefined;
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
    const ids = [...new Set([...reflectionSources.flat(), ...facts.flatMap((fact) => fact.document_id ? [fact.document_id] : [])])].slice(0, 30);
    const documents: MemoryDocument[] = [];
    for (const id of ids) {
      const document = await this.source(identity, scopeId, id, signal);
      if (document) documents.push(document);
      if (documents.length === 5) break;
    }
    let current = await this.readable(identity, scopeId);
    // A later source read can race with an earlier one. Publish only a stable validation pass.
    for (let attempt = 0; attempt < 3; attempt++) {
      const generation = current.generation;
      for (let i = documents.length - 1; i >= 0; i--) {
        const verified = await this.source(identity, scopeId, documents[i]!.id, signal);
        if (!verified || verified.source.revision !== documents[i]!.source.revision) documents.splice(i, 1);
      }
      current = await this.readable(identity, scopeId);
      if (current.generation === generation) break;
      if (attempt === 2) throw new HindsightError("memory_source_changed");
    }

    const verified = new Set(documents.map((document) => document.id));
    const referenceCount = reflectionFacts.length + reflectionModels.length;
    const allReferencesVerified = referenceCount > 0
      && reflectionSources.length === referenceCount
      && reflectionSources.every((ids) => ids.length > 0 && ids.every((id) => verified.has(id)));
    const hypothesis = allReferencesVerified && current.generation === state.generation && !current.reconcile ? reflection?.text : undefined;
    const skippedCount = Object.keys(current.progress?.failures ?? {}).length;
    let coverage = skippedCount ? "partial" : "ready";
    if (current.reconcile || current.generation !== current.indexedGeneration) coverage = "updating";
    return { sources: documents.map((document) => ({
      kind: document.source.kind, id: document.source.id, revision: document.source.revision,
      meeting_id: document.source.kind === "meeting" ? encodeId("meeting", document.source.id) : null,
      workspace_id: this.store.personal ? null : encodeId("workspace", scopeId),
      scope: this.store.personal ? "personal" : "workspace",
      // Only canonical Dahlia content is evidence. Memory extraction is never returned as a fact.
      canonicalExcerpt: document.content.slice(0, 16_000), truncated: document.content.length > 16_000,
    })), hypothesis: hypothesis ?? null,
    coverage,
    skippedCount,
    instruction: "Cite these Dahlia sources. A transcript proves that a statement was recorded, not that it is objectively true. The hypothesis is an unverified interpretation: check claims against the canonical excerpts and meeting tools. If coverage is not ready, disclose incomplete memory coverage and use canonical tools for the omitted sources. Do not infer counts or trends from retrieval hits." };
  }

  async step(scopeId: string, signal: AbortSignal) {
    signal = AbortSignal.any([signal, AbortSignal.timeout(90_000)]);
    const job = await this.store.claim(scopeId);
    if (!job) return;
    try {
      if (job.purge || !await this.store.exists(scopeId)) {
        const source = await this.store.pending(scopeId);
        for (const id of [job.progress?.operationId, source?.operation?.id]) {
          if (!id) continue;
          const status = await this.client.operation(job.bankId, id, signal);
          if (status === "pending" || status === "processing") { await this.store.release(job); return; }
        }
        await this.client.deleteBank(job.bankId, signal);
        await this.store.purged(job);
        return;
      }
      if (!job.enabled) { await this.store.release(job, { availableAt: new Date(Date.now() + 60_000) }); return; }
      if (job.bankId !== this.client.bank(scopeId, this.store.personal)) throw new HindsightError("memory_bank_config_changed");
      const workerUser = await this.store.workerUser(scopeId);
      if (!workerUser) throw new HindsightError("memory_authorization_changed");
      const identity: Identity = { userId: workerUser, source: "accounts" };
      if (!this.store.personal) {
        const workspace = await this.sync.getWorkspace(identity, scopeId);
        if (!workspace || workspace.role !== "admin" || workspace.encryption === "server") throw new HindsightError("memory_authorization_changed");
      }
      if (!job.reconcile && job.indexedGeneration === job.generation) {
        await this.store.release(job, { availableAt: new Date(Date.now() + 60_000) }); return;
      }
      let progress = job.progress;
      if (!progress) {
        await this.client.initialize(job.bankId, signal, this.store.personal);
        progress = { phase: this.store.personal ? "notes" : "meetings", dirtyModels: ["workspace"] };
        await this.store.startScan(job, progress);
      }
      if (progress.operationId) {
        const modelId = progress.modelId!;
        const status = await this.client.operation(job.bankId, progress.operationId, signal);
        if (status === "pending" || status === "processing") { await this.store.release(job); return; }
        if (status === "failed" || status === "cancelled") {
          if ((progress.operationAttempts ?? 0) < 3) {
            progress.operationAttempts = (progress.operationAttempts ?? 0) + 1;
            await this.store.setProgress(job, progress);
            await this.client.retryOperation(job.bankId, progress.operationId, signal);
            await this.store.release(job); return;
          }
          await this.client.deleteModel(job.bankId, modelId, signal);
          this.skip(progress, modelId, "memory_operation_failed");
        }
        if (status === "completed") this.unskip(progress, modelId);
        if (status !== "not_found") progress.dirtyModels = progress.dirtyModels?.filter((id) => this.modelId(id) !== modelId);
        progress = { ...progress, operationId: undefined, modelId: undefined, operationAttempts: undefined };
        await this.store.setProgress(job, progress);
      }
      // A requested rescan is independent of ordinary source changes and never rewinds an active scan.
      if (job.reconcile && progress.phase === "delta") {
        const failedModels = Object.keys(progress.failures ?? {}).flatMap((id) =>
          id === "workspace-insights" ? ["workspace"] : id.startsWith("project-") ? [id.slice("project-".length)] : []);
        progress = { ...progress, phase: this.store.personal ? "notes" : "meetings", after: undefined, failures: {},
          dirtyModels: [...new Set([...(progress.dirtyModels ?? []), ...failedModels])] };
        await this.store.startScan(job, progress);
      }
      if (progress.phase === "meetings") {
        const [createdAt, meetingId] = progress.after?.split(",") ?? [];
        const cursor = progress.after ? { createdAt: new Date(createdAt!), meetingId: meetingId! } : undefined;
        const [meeting] = await this.syncStore.withIdentity(identity, (scoped) => scoped.listMeetings(scopeId, undefined, 1, undefined, cursor));
        if (meeting) {
          if (!meeting.isRecording && meeting.status === "READY") await this.store.enqueue(scopeId, "meeting", meeting.meetingId);
          progress.after = `${meeting.createdAt.toISOString()},${meeting.meetingId}`;
        } else progress = { ...progress, phase: "notes", after: undefined };
      } else if (progress.phase === "notes") {
        const [note] = await this.store.listNotes(identity.userId, scopeId, progress.after);
        if (note) { await this.store.enqueue(scopeId, "shared", note.id); progress.after = note.id; }
        else progress = { ...progress, phase: "cleanup", after: undefined };
      } else if (progress.phase === "cleanup") {
        // Recheck indexed documents too, including sources deleted while ingestion was paused.
        const rows = await this.store.documents(scopeId, progress.after);
        for (const row of rows) await this.store.enqueue(scopeId, row.source.kind, row.source.id);
        progress = rows.length === 100 ? { ...progress, after: rows.at(-1)!.documentId } : { ...progress, phase: "delta", after: undefined };
      } else {
        const source = await this.store.pending(scopeId);
        if (source) await this.processSource(job, progress, source, identity, signal);
        else if (progress.dirtyModels?.length) {
          const id = progress.dirtyModels[0]!;
          const modelId = this.modelId(id);
          // Persist the model identity before the external create; GET + refresh recovers a lost acknowledgement.
          progress.modelId = modelId;
          await this.store.setProgress(job, progress);
          const operationId = await this.client.createModel(job.bankId, id === "workspace" ? null : id, signal, this.store.personal);
          progress = { ...progress, operationId, operationAttempts: 0 };
          await this.store.setProgress(job, progress);
        } else {
          await this.store.release(job, { indexedGeneration: job.generation, status: "ready", progress,
            attempts: 0, errorCode: null, availableAt: new Date(Date.now() + 60_000) });
          return;
        }
      }
      await this.store.release(job, { progress, status: "indexing", attempts: 0, errorCode: null });
    } catch (error) {
      const code = error instanceof HindsightError ? error.code : error instanceof RequestError ? "memory_source_unavailable" : "memory_processing_failed";
      await this.store.release(job, { status: "error", errorCode: code, attempts: job.attempts + 1,
        availableAt: new Date(Date.now() + Math.min(300_000, 5_000 * 2 ** Math.min(job.attempts, 6))) });
    }
  }
  private modelId(id: string) { return id === "workspace" ? "workspace-insights" : `project-${id}`; }
  private async processSource(job: MemoryState, progress: MemoryProgress, pending: MemorySourceJob, identity: Identity, signal: AbortSignal) {
    const previous = await this.store.document(job.scopeId, pending.documentId);
    const markModelsDirty = async (projectId?: string | null) => {
      progress.dirtyModels = [...new Set([...(progress.dirtyModels ?? []), "workspace",
        ...[previous?.source.projectId, projectId].filter((id): id is string => !!id)])];
      await this.store.setProgress(job, progress);
    };
    const operation = pending.operation;
    if (operation) {
      const status = await this.client.operation(job.bankId, operation.id, signal);
      if (status === "pending" || status === "processing") return;
      if (status === "completed") {
        this.unskip(progress, pending.documentId);
        await markModelsDirty(operation.source.projectId);
        await this.store.saveDocument({ ...job, generation: operation.generation }, pending.documentId, operation.source, operation.contentHash);
        await this.store.finishSource({ ...pending, generation: operation.generation });
        return;
      }
      if (status === "failed" || status === "cancelled") {
        if (operation.generation === pending.generation && operation.attempts < 3) {
          await this.store.setOperation(pending, { ...operation, attempts: operation.attempts + 1 });
          await this.client.retryOperation(job.bankId, operation.id, signal);
          return;
        }
        await markModelsDirty(operation.source.projectId);
        await this.client.deleteDocument(job.bankId, pending.documentId, signal);
        await this.store.forgetDocument(job.scopeId, pending.documentId);
        if (operation.generation === pending.generation) this.skip(progress, pending.documentId, "memory_operation_failed");
        await this.store.setProgress(job, progress);
        await this.store.finishSource({ ...pending, generation: operation.generation });
        return;
      }
    }
    let document: MemoryDocument | null;
    try {
      document = pending.kind === "meeting"
        ? await meetingDocument(this.sync, identity, job.scopeId, pending.sourceId, signal)
        : await this.store.getNote(identity.userId, job.scopeId, pending.sourceId).then((note) => note ? noteDocument(note, this.store.personal) : null);
      if (!document) this.unskip(progress, pending.documentId);
    } catch (error) {
      if (!(error instanceof HindsightError) || error.code !== "memory_source_too_large") throw error;
      this.skip(progress, pending.documentId, error.code);
      document = null;
    }
    const hash = document ? await contentHash(document.content) : null;
    if (!operation && document && previous && previous.generation > 0 && previous.contentHash === hash) {
      this.unskip(progress, pending.documentId);
      await this.store.saveDocument(job, pending.documentId, document.source, hash);
      // Persist recovery before removing the only durable retry entry.
      await this.store.setProgress(job, progress);
      await this.store.finishSource(pending);
      return;
    }
    await markModelsDirty(document?.source.projectId);
    if (!document) {
      await this.client.deleteDocument(job.bankId, pending.documentId, signal);
      await this.store.forgetDocument(job.scopeId, pending.documentId);
      await this.store.setProgress(job, progress);
      await this.store.finishSource(pending);
      return;
    }
    // Only replay a lost operation when its exact canonical input still exists.
    const id = operation?.generation === pending.generation && operation.contentHash === hash ? operation.id : uuidV7();
    await this.store.setOperation(pending, { id, generation: pending.generation, source: document.source, contentHash: hash!, attempts: 0 });
    await this.client.retain(job.bankId, document, id, signal, this.store.personal);
  }
  private unskip(progress: MemoryProgress, source: string) {
    delete progress.failures?.[source];
  }
  private skip(progress: MemoryProgress, source: string, code: string) {
    this.unskip(progress, source);
    // Keep every failure identity for recovery; only public diagnostics are capped.
    (progress.failures ??= {})[source] = code;
  }
}

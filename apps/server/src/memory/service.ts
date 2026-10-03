import { imageCoverage, imageDocument, imageReferences, validImageLineage, type ImageSettings } from "./images";
import { canonicalJson } from "../sync/service";
import { ingestionFingerprint, ingestionPolicy } from "./ingestion";
import { KnowledgePages } from "./pages";
import type { AppConfig } from "../config";
import type { Identity } from "../auth/identity";
import type { MeetingSyncService } from "../sync/service";
import type { MeetingSyncStore } from "../sync/types";
import { RequestError } from "../storage/upload";
import { DatabricksTokenError } from "../databricks/token";
import { uuidV7 } from "@dahlia-ai/ui/model/id";
import { encodeId } from "@dahlia-ai/ui/model/typeid";
import { HindsightClient, HindsightError, type HindsightBudget, type HindsightRecall, type HindsightTags } from "./hindsight";
import { canonicalExcerpt, markerIds } from "./excerpt";
import { parseReflection, type MemoryClaim, type ReflectionStatus } from "./reflection";
import type { MemoryDocument, MemoryProgress } from "./model";
import { contentHash, meetingDocument, noteDocument } from "./sources";
import type { MemoryState, MemoryStore, MemorySourceJob } from "./store";
import { memoryDocumentId, memoryDocumentSource } from "./ids";

export type MemoryDepth = "quick" | "normal" | "deep";
// projectId is a Project UUID; after/before are ISO datetimes that only rank the period higher.
export interface MemorySearchInput { projectId?: string; after?: string; before?: string; depth?: MemoryDepth }
const budgets: Record<MemoryDepth, HindsightBudget> = { quick: "low", normal: "mid", deep: "high" };

export function temporalWindow(input: MemorySearchInput, now = new Date()) {
  if (input.after === undefined && input.before === undefined) return undefined;
  const start = new Date(input.after ?? 0), end = input.before === undefined ? now : new Date(input.before);
  if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime()) || start > end) {
    throw new RequestError(400, "memory_time_range_invalid");
  }
  return { start: start.toISOString(), end: end.toISOString() };
}

export class WorkspaceMemoryService {
  readonly client: HindsightClient;
  private readonly imageSettings?: ImageSettings;
  readonly pages: KnowledgePages;
  constructor(config: AppConfig, readonly store: MemoryStore, private readonly sync: MeetingSyncService,
    private readonly syncStore: MeetingSyncStore, transport: typeof fetch = fetch) {
    this.imageSettings = config.hindsight?.images;
    this.client = new HindsightClient(config.hindsight!, config.databricksWorkspace, transport);
    this.pages = new KnowledgePages(this, store, sync);
  }
  async status(identity: Identity, scopeId: string) {
    const state = await this.store.status(identity.userId, scopeId);
    const failures = Object.entries(state?.progress?.failures ?? {});
    let status = "paused";
    if (state?.purge) status = "deleting";
    else if (state?.enabled) {
      if (state.progress?.entityPolicy !== 1 || state.progress?.reflectionPolicy !== 1 || !state.progress?.ingestionPolicy) status = state.status === "error" ? "error" : "indexing";
      else if (state.status === "error" || state.reconcile || state.indexedGeneration !== state.generation) status = state.status;
      else status = failures.length ? "partial" : "ready";
    }
    return { enabled: state?.enabled ?? false, ...(!this.store.personal ? { imagesEnabled: state?.imagesEnabled ?? false, imagesAvailable: !!this.imageSettings } : {}), status,
      errorCode: state?.errorCode ?? null, attempts: state?.attempts ?? 0,
      skippedCount: failures.length, skippedSources: failures.slice(-20).map(([source, code]) => ({ source, code })) };
  }
  async configure(identity: Identity, scopeId: string, enabled: boolean, imagesEnabled?: boolean) {
    if (imagesEnabled !== undefined) {
      if (this.store.personal) throw new RequestError(400, "memory_images_workspace_only");
      const workspace = await this.sync.getWorkspace(identity, scopeId);
      if (!workspace || workspace.role !== "admin") throw new RequestError(404, "workspace_not_found");
      if (imagesEnabled) {
        const bank = this.client.bank(scopeId), signal = AbortSignal.timeout(30_000);
        try { await this.client.imageConfiguration(bank, this.imageSettings, signal); }
        catch (error) {
          if (!(error instanceof HindsightError) || error.status !== 404) throw error;
          // The first opt-in can precede the worker's initial bank creation.
          await this.client.initialize(bank, signal);
          await this.client.imageConfiguration(bank, this.imageSettings, signal);
        }
      }
    }
    return this.store.configure(identity.userId, scopeId, this.client.bank(scopeId, this.store.personal), enabled, imagesEnabled);
  }
  private images(state: MemoryState) { return !this.store.personal && state.imagesEnabled ? this.imageSettings : undefined; }
  private async document(identity: Identity, state: MemoryState, id: string, signal: AbortSignal, saved?: MemoryDocument["source"]["images"], materialize = false) {
    const document = await meetingDocument(this.sync, identity, state.scopeId, id, signal);
    if (!document || !state.imagesEnabled || this.store.personal) return document;
    if (!this.imageSettings) throw new HindsightError("memory_images_unconfigured");
    return imageDocument(document, this.sync, this.syncStore, identity, state.scopeId, this.imageSettings, signal, saved, materialize);
  }
  private async readable(identity: Identity, scopeId: string) {
    const state = await this.store.status(identity.userId, scopeId);
    if (!state?.enabled || state.purge || (state.progress?.entityPolicy !== 1 || state.progress?.reflectionPolicy !== 1) || state.bankId !== this.client.bank(scopeId, this.store.personal)) {
      throw new HindsightError("memory_not_ready");
    }
    return state;
  }
  async policyCurrent(state: MemoryState, signal: AbortSignal) {
    if (state.imagesEnabled && !this.store.personal) await this.client.imageConfiguration(state.bankId, this.imageSettings, signal);
    const upstream = await this.client.ingestionPolicy(state.bankId, signal);
    return state.progress?.upstreamPolicy === upstream && state.progress.ingestionPolicy === await ingestionPolicy(upstream, this.images(state));
  }
  private updating() {
    return { sources: [], hypothesis: null, claims: [], reflectionStatus: "updating" as const, reflectionUsage: null,
      coverage: "updating", skippedCount: 0, skippedSources: [],
      instruction: "Memory settings are being reprocessed. Disclose incomplete coverage; use canonical tools. No old analysis is published." };
  }
  async canonicalSource(identity: Identity, scopeId: string, documentId: string, signal: AbortSignal) {
    const source = memoryDocumentSource(documentId);
    if (!source || (this.store.personal && source.kind !== "shared")) return null;
    const saved = await this.store.document(scopeId, documentId);
    if (!saved || saved.source.kind !== source.kind || saved.source.id !== source.id
      || saved.generation <= 0 || await this.store.pending(scopeId, documentId)) return null;
    const state = await this.store.status(identity.userId, scopeId);
    if (!state?.enabled || state.purge || state.bankId !== this.client.bank(scopeId, this.store.personal) || !state.progress?.ingestionPolicy) return null;
    const document = saved.source.kind === "meeting"
      ? await this.document(identity, state, saved.source.id, signal, saved.source.images)
      : await this.store.getNote(identity.userId, scopeId, saved.source.id).then((note) => note ? noteDocument(note, this.store.personal) : null);
    if (!document || document.id !== documentId || document.source.revision !== saved.source.revision) return null;
    const hash = await contentHash(document.content);
    return hash === saved.contentHash && saved.ingestionFingerprint === await ingestionFingerprint(hash, document.source, state.progress.ingestionPolicy)
      ? document : null;
  }
  async search(identity: Identity, scopeId: string, query: string, reflect: boolean, signal: AbortSignal, input: MemorySearchInput = {}) {
    signal = AbortSignal.any([signal, AbortSignal.timeout(30_000)]);
    const window = temporalWindow(input);
    if (input.projectId && !await this.sync.getProject(identity, scopeId, input.projectId)) throw new RequestError(404, "project_not_found");
    const scope: HindsightTags | undefined = input.projectId ? { tags: [`project:${input.projectId}`], tagsMatch: "all_strict" } : undefined;
    const state = await this.readable(identity, scopeId);
    if (!await this.policyCurrent(state, signal)) return this.updating();
    const reflection = reflect && !window && !state.reconcile && state.generation === state.indexedGeneration ? await this.client.reflect(state.bankId, query, signal, scope) : undefined;
    const recall = await this.client.recall(state.bankId, query, signal,
      { ...scope, temporalWindow: window, budget: budgets[input.depth ?? "normal"] });
    const chunks = recallChunks(recall);
    const parsed = reflection ? parseReflection(reflection) : undefined;
    let reflectionStatus: ReflectionStatus = !reflect ? "not_requested" : window ? "temporal_unavailable"
      : !reflection ? "updating" : parsed!.status;
    const basedOn = new Set(reflection?.based_on?.memories.map((fact) => fact.id).filter((id): id is string => !!id));
    const validate = async (id: string, fact: { attachments?: Parameters<typeof validImageLineage>[1]; metadata?: Record<string, unknown> | null }) => {
      const document = await this.canonicalSource(identity, scopeId, id, signal);
      return !!document && validImageLineage(document, fact.attachments, fact.metadata);
    };
    const reflectionSources = new Map<string, string[]>();
    const candidates = parsed?.claims ?? [];
    for (const claim of candidates) {
      // Validate membership before any lookup; never let a generated ID select unrelated facts.
      if (!claim.factIds.every((id) => basedOn.has(id))) continue;
      for (const id of new Set(claim.factIds)) {
        if (!reflectionSources.has(id) && reflectionSources.size < 10) {
          reflectionSources.set(id, await this.client.factDocuments(state.bankId, id, signal, chunks, validate));
        }
      }
    }
    const documents: MemoryDocument[] = [];
    const checked = new Map<string, MemoryDocument | null>();
    const source = async (id: string) => {
      if (checked.has(id)) return checked.get(id);
      if (checked.size === 30) return null;
      const document = await this.canonicalSource(identity, scopeId, id, signal);
      // Canonical data, not the analysis copy, decides Project membership.
      let imageValid = true;
      if (document?.source.images?.entries.length) {
        imageValid = false;
        for (const fact of recall.results.slice(0, 30)) {
          if (fact.document_id && fact.document_id !== id) continue;
          const ids = await this.client.factDocuments(state.bankId, fact.id, signal, undefined, validate);
          if (ids.includes(id)) { imageValid = true; break; }
        }
        if ([...reflectionSources.values()].some((ids) => ids.includes(id))) imageValid = true;
      }
      const valid = imageValid && document && (!input.projectId || document.source.projectId === input.projectId) ? document : null;
      checked.set(id, valid);
      return valid;
    };
    for (const claim of candidates) {
      const lineages = claim.factIds.map((id) => reflectionSources.get(id));
      if (lineages.some((ids) => !ids?.length)) continue;
      const ids = [...new Set(lineages.flatMap((ids) => ids!))].filter((id) => !documents.some((document) => document.id === id));
      if (documents.length + ids.length > 5) continue;
      const group: MemoryDocument[] = [];
      for (const id of ids) {
        const document = await source(id);
        if (!document) break;
        group.push(document);
      }
      // Reserve slots only when the whole claim has current canonical evidence.
      if (group.length === ids.length) documents.push(...group);
    }
    for (const id of chunks.keys()) {
      if (documents.length === 5) break;
      if (documents.some((document) => document.id === id)) continue;
      const document = await source(id);
      if (document) documents.push(document);
    }
    const markers = new Map<string, string[]>();
    // Chunk retrieval improves excerpts, but must leave time for canonical revalidation.
    const excerptSignal = AbortSignal.any([signal, AbortSignal.timeout(3_000)]);
    for (const document of documents) {
      if (document.content.length > 16_000) markers.set(document.id,
        await this.markers(state.bankId, document.id, chunks.get(document.id) ?? [], recall, excerptSignal, signal));
    }
    let current = await this.readable(identity, scopeId);
    // A later source read can race with an earlier one. Publish only a stable validation pass.
    for (let attempt = 0; attempt < 3; attempt++) {
      const generation = current.generation;
      for (let i = documents.length - 1; i >= 0; i--) {
        const verified = await this.canonicalSource(identity, scopeId, documents[i]!.id, signal);
        if (!verified || canonicalJson(verified.source) !== canonicalJson(documents[i]!.source)) documents.splice(i, 1);
      }
      current = await this.readable(identity, scopeId);
      if (current.generation === generation) break;
      if (attempt === 2) throw new HindsightError("memory_source_changed");
    }

    if (!await this.policyCurrent(current, signal)) return this.updating();
    // The last config request is also an external boundary: recheck authorization and generation.
    const published = await this.readable(identity, scopeId);
    if (published.generation !== current.generation || published.progress?.ingestionPolicy !== state.progress?.ingestionPolicy) return this.updating();
    signal.throwIfAborted();
    const indexes = new Map(documents.map((document, index) => [document.id, index]));
    const claims: MemoryClaim[] = [];
    if (candidates.length && current.generation === state.generation && !current.reconcile) {
      for (const claim of candidates) {
        const citations: MemoryClaim["citations"] = [];
        for (const factId of new Set(claim.factIds)) {
          const ids = reflectionSources.get(factId);
          if (!basedOn.has(factId) || !ids?.length || ids.some((id) => !indexes.has(id))) break;
          citations.push({ factId, sourceIndexes: ids.map((id) => indexes.get(id)!) });
        }
        if (citations.length === new Set(claim.factIds).size) claims.push({ text: claim.text, citations });
      }
      reflectionStatus = claims.length === parsed?.totalClaims ? "ready" : claims.length ? "partial" : "invalid_references";
    } else if (reflect && !window && current.generation !== state.generation) reflectionStatus = "updating";
    const hypothesis = claims.length ? claims.map((claim) => claim.text).join("\n\n") : null;
    const skippedCount = Object.keys(current.progress?.failures ?? {}).length;
    let coverage = skippedCount ? "partial" : "ready";
    if (current.reconcile || current.generation !== current.indexedGeneration) coverage = "updating";
    return { sources: documents.map((document) => {
      // Only canonical Dahlia content is evidence. Memory extraction is never returned as a fact.
      const excerpt = canonicalExcerpt(document, markers.get(document.id) ?? []);
      return { kind: document.source.kind, id: document.source.id, revision: document.source.revision,
        meeting_id: document.source.kind === "meeting" ? encodeId("meeting", document.source.id) : null,
        workspace_id: this.store.personal ? null : encodeId("workspace", scopeId),
        scope: this.store.personal ? "personal" : "workspace", images: imageReferences(document), imageCoverage: imageCoverage(document),
        canonicalExcerpt: excerpt.text, truncated: excerpt.truncated };
    }), hypothesis, claims, reflectionStatus,
    reflectionUsage: reflection?.usage ? { inputTokens: reflection.usage.input_tokens, outputTokens: reflection.usage.output_tokens } : null,
    coverage,
    skippedCount,
    skippedSources: Object.entries(current.progress?.failures ?? {}).slice(-20).map(([source, code]) => ({ source, code })),
    instruction: (reflect && window ? "Temporal reflection is unavailable: this response contains recall sources only, with no hypothesis. The period affects ranking, not exclusion. " : "") + "Cite these Dahlia sources. A transcript proves that a statement was recorded, not that it is objectively true. The hypothesis is an unverified interpretation: check claims against the canonical excerpts and meeting tools. If coverage is not ready, disclose incomplete memory coverage and use canonical tools for the omitted sources. All references sharing meeting_id are one evidence group, including transcript, summary, OCR and caption; fact counts are not independent corroboration. Do not infer counts or trends from retrieval hits." };
  }

  // Chunk text only yields segment and screenshot IDs; missing or cut-off chunks are read back, at most three per document.
  private async markers(bank: string, documentId: string, chunkIds: string[], recall: HindsightRecall, signal: AbortSignal, parentSignal: AbortSignal) {
    const ids: string[] = [];
    let reads = 0;
    for (const chunkId of chunkIds) {
      const recalled = recall.chunks?.[chunkId];
      let text = recalled && !recalled.truncated ? recalled.text : undefined;
      if (text === undefined && reads < 3 && !signal.aborted) {
        reads++;
        try {
          const chunk = await this.client.chunk(bank, chunkId, signal);
          if (chunk?.documentId === documentId) text = chunk.text;
        } catch (error) {
          parentSignal.throwIfAborted();
          if (error instanceof DatabricksTokenError && !error.retryable) throw error;
          if (error instanceof HindsightError && (error.status === 401 || error.status === 403)) throw error;
          // Optional hints can fail; the evidence still comes from the verified canonical document.
        }
      }
      if (text !== undefined) ids.push(...markerIds(text));
    }
    return [...new Set(ids)];
  }

  async step(scopeId: string, signal: AbortSignal, supplied?: import("../jobs/store").BackgroundJob) {
    signal = AbortSignal.any([signal, AbortSignal.timeout(90_000)]);
    let job = await this.store.claim(scopeId, supplied);
    if (!job) return;
    try {
      if (job.bankId !== this.client.bank(scopeId, this.store.personal)) throw new HindsightError("memory_bank_config_changed");
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
      const workerUser = await this.store.workerUser(scopeId);
      if (!workerUser) throw new HindsightError("memory_authorization_changed");
      const identity: Identity = { userId: workerUser, source: "accounts" };
      if (!this.store.personal) {
        const workspace = await this.sync.getWorkspace(identity, scopeId);
        if (!workspace || workspace.role !== "admin" || workspace.encryption === "server") throw new HindsightError("memory_authorization_changed");
      }
      let progress = job.progress;
      if (progress && (progress.entityPolicy !== 1 || progress.reflectionPolicy !== 1)) {
        await this.client.initialize(job.bankId, signal, this.store.personal);
        progress = { ...progress, entityPolicy: 1, reflectionPolicy: 1 };
        await this.store.setProgress(job, progress);
      }
      if (!progress) {
        await this.client.initialize(job.bankId, signal, this.store.personal);
        progress = { entityPolicy: 1, reflectionPolicy: 1, phase: this.store.personal ? "notes" : "meetings", dirtyModels: ["workspace"] };
      }
      const upstreamPolicy = await this.client.ingestionPolicy(job.bankId, signal);
      if (job.imagesEnabled && !this.store.personal) await this.client.imageConfiguration(job.bankId, this.imageSettings, signal);
      const policy = await ingestionPolicy(upstreamPolicy, this.images(job));
      if (progress.ingestionPolicy !== policy) {
        progress = { ...progress, ingestionPolicy: policy, upstreamPolicy, phase: "delta", after: undefined, pageAfter: undefined };
        job = await this.store.changeIngestionPolicy(job, progress);
      }
      if (!job.reconcile && job.indexedGeneration === job.generation) {
        if (!this.store.personal) {
          const pageAfter = await this.pages.step(identity, { ...job, progress }, signal);
          progress = { ...progress, pageAfter };
        }
        await this.store.release(job, { progress, status: "ready", attempts: 0, errorCode: null,
          availableAt: new Date(Date.now() + (progress.pageAfter ? 5_000 : 60_000)) }); return;
      }
      if (progress.operationId) {
        const modelId = progress.modelId!;
        const detail = await this.client.operationDetail(job.bankId, progress.operationId, signal);
        const status = detail.status;
        if (status === "pending" || status === "processing") { await this.store.release(job); return; }
        if (status === "failed" || status === "cancelled") {
          if (!detail.dahlia_error_code && (progress.operationAttempts ?? 0) < 3) {
            progress.operationAttempts = (progress.operationAttempts ?? 0) + 1;
            await this.store.setProgress(job, progress);
            await this.client.retryOperation(job.bankId, progress.operationId, signal);
            await this.store.release(job); return;
          }
          await this.client.deleteModel(job.bankId, modelId, signal);
          this.skip(progress, modelId, detail.dahlia_error_code ?? "memory_operation_failed");
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
        if (source) {
          try { await this.processSource(job, progress, source, identity, signal); }
          catch (error) {
            signal.throwIfAborted();
            if (!(error instanceof HindsightError) || !["memory_image_unavailable", "memory_image_changed", "memory_image_too_large"].includes(error.code)
              || (error.code !== "memory_image_too_large" && job.attempts < 3)) throw error;
            const operation = source.operation && await this.client.operation(job.bankId, source.operation.id, signal);
            if (operation === "pending" || operation === "processing") throw error;
            const old = await this.store.document(job.scopeId, source.documentId);
            await this.client.deleteDocument(job.bankId, source.documentId, signal);
            await this.store.forgetDocument(job.scopeId, source.documentId);
            this.skip(progress, source.documentId, error.code);
            progress.dirtyModels = [...new Set([...(progress.dirtyModels ?? []), "workspace", ...(old?.source.projectId ? [old.source.projectId] : [])])];
            await this.store.setProgress(job, progress);
            await this.store.finishSource(source);
          }
        }
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
    if (pending.documentId !== memoryDocumentId(pending.kind, pending.sourceId) || (this.store.personal && pending.kind !== "shared")
      || (pending.operation && (pending.operation.source.kind !== pending.kind || pending.operation.source.id !== pending.sourceId))) {
      throw new HindsightError("memory_document_mismatch");
    }
    const previous = await this.store.document(job.scopeId, pending.documentId);
    const markModelsDirty = async (projectId?: string | null) => {
      progress.dirtyModels = [...new Set([...(progress.dirtyModels ?? []), "workspace",
        ...[previous?.source.projectId, projectId].filter((id): id is string => !!id)])];
      await this.store.setProgress(job, progress);
    };
    const read = async () => pending.kind === "meeting"
      ? this.document(identity, job, pending.sourceId, signal, previous?.source.images)
      : this.store.getNote(identity.userId, job.scopeId, pending.sourceId).then((note) => note ? noteDocument(note, this.store.personal) : null);
    let document: MemoryDocument | null;
    try {
      document = await read();
      if (!document) this.unskip(progress, pending.documentId);
    } catch (error) {
      if (!(error instanceof HindsightError) || error.code !== "memory_source_too_large") throw error;
      this.skip(progress, pending.documentId, error.code);
      document = null;
    }
    const hash = document ? await contentHash(document.content) : null;
    const fingerprint = document ? await ingestionFingerprint(hash!, document.source, progress.ingestionPolicy!) : null;
    const fail = async (code: string) => {
      await markModelsDirty(document?.source.projectId);
      await this.client.deleteDocument(job.bankId, pending.documentId, signal);
      await this.store.forgetDocument(job.scopeId, pending.documentId);
      this.skip(progress, pending.documentId, code);
      await this.store.setProgress(job, progress);
      await this.store.finishSource(pending);
    };
    const submit = async (operation: NonNullable<MemorySourceJob["operation"]>) => {
      await this.store.setOperation(pending, operation);
      if (operation.stage === "reprocess") {
        try { await this.client.reprocess(job.bankId, pending.documentId, operation.id, signal); return; }
        catch (error) {
          signal.throwIfAborted();
          if (!(error instanceof HindsightError) || error.status !== 404) throw error;
        }
        // The disposable upstream document disappeared. Recreate from the current canonical
        // input; a different operation kind must never reuse the reprocess idempotency key.
        operation = { ...operation, id: uuidV7(), stage: "retain", reprocess: false, attempts: 0 };
        await this.store.setOperation(pending, operation);
      }
      const sent = document!.source.kind === "meeting" && job.imagesEnabled
        ? await this.document(identity, job, pending.sourceId, signal, document!.source.images, true) : document;
      if (!sent || canonicalJson(sent.source) !== canonicalJson(document!.source)) throw new HindsightError("memory_image_changed");
      await this.client.retain(job.bankId, sent, operation.id, signal, this.store.personal, progress.upstreamPolicy);
    };
    const operation = pending.operation;
    if (operation) {
      const detail = await this.client.operationDetail(job.bankId, operation.id, signal), status = detail.status;
      if (status === "pending" || status === "processing") return;
      const same = document && operation.generation === pending.generation && operation.ingestionFingerprint === fingerprint
        && operation.policy === progress.ingestionPolicy;
      if (same && status === "not_found") { await submit(operation); return; }
      if (same && (status === "failed" || status === "cancelled")) {
        if (!detail.dahlia_error_code && operation.attempts < 3) {
          await this.store.setOperation(pending, { ...operation, attempts: operation.attempts + 1 });
          await this.client.retryOperation(job.bankId, operation.id, signal);
        } else await fail(detail.dahlia_error_code ?? "memory_operation_failed");
        return;
      }
      if (same && document && status === "completed") {
        const stored = await this.client.document(job.bankId, pending.documentId, signal);
        const metadata = stored?.retain_params?.metadata;
        if ((document.source.images ? metadata?.dahlia_image_manifest !== canonicalJson(document.source.images)
          || !this.client.matchesImages(stored, document) : stored?.original_text !== document.content) || metadata?.source_revision !== document.source.revision
          || metadata?.source_id !== document.source.id || metadata?.source_kind !== document.source.kind) {
          await fail("memory_document_mismatch"); return;
        }
        if (operation.stage === "retain" && operation.reprocess) {
          await submit({ ...operation, id: uuidV7(), stage: "reprocess", attempts: 0 }); return;
        }
        if (metadata?.dahlia_ingestion_policy === progress.upstreamPolicy) {
          if (!stored?.memory_unit_count) { await fail("memory_no_facts"); return; }
          // Validate again after all upstream work. A new source/settings generation cannot adopt this operation.
          if (!await this.policyCurrent(job, signal)) return;
          const latest = await read(), current = await this.store.status(identity.userId, job.scopeId);
          const sourceJob = await this.store.pending(job.scopeId, pending.documentId);
          if (!current?.enabled || current.purge || current.bankId !== job.bankId || current.generation !== job.generation || sourceJob?.generation !== operation.generation
            || !latest || await ingestionFingerprint(await contentHash(latest.content), latest.source, progress.ingestionPolicy!) !== fingerprint) return;
          this.unskip(progress, pending.documentId);
          await markModelsDirty(document.source.projectId);
          await this.store.saveDocument(job, pending.documentId, document.source, hash!, fingerprint);
          await this.store.finishSource(pending);
          return;
        }
        // Extraction used a different live configuration. Never relabel it as this recipe.
      }
      await this.store.setOperation(pending, null);
    }
    if (!operation && document && previous?.generation && previous.ingestionFingerprint === fingerprint) {
      this.unskip(progress, pending.documentId);
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
    const stored = await this.client.document(job.bankId, pending.documentId, signal);
    const reprocess = !!stored && (!!operation || stored.retain_params?.metadata?.dahlia_ingestion_policy !== progress.upstreamPolicy || !previous || previous.ingestionFingerprint !==
      await ingestionFingerprint(previous.contentHash, previous.source, progress.ingestionPolicy!));
    await submit({ id: uuidV7(), generation: pending.generation, source: document.source, contentHash: hash!,
      ingestionFingerprint: fingerprint!, policy: progress.ingestionPolicy, stage: "retain", reprocess, attempts: 0 });
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
// Candidate documents in recall order with the chunks their facts came from. An observation stands for its source facts.
function recallChunks(recall: HindsightRecall) {
  const documents = new Map<string, string[]>();
  const add = (documentId: string | null | undefined, chunkId: string | null | undefined) => {
    if (!documentId) return;
    const chunks = documents.get(documentId) ?? [];
    if (chunkId && !chunks.includes(chunkId)) chunks.push(chunkId);
    documents.set(documentId, chunks);
  };
  for (const fact of recall.results) {
    if (fact.type !== "observation") add(fact.document_id, fact.chunk_id);
    else for (const id of fact.source_fact_ids ?? []) add(recall.source_facts?.[id]?.document_id, recall.source_facts?.[id]?.chunk_id);
  }
  return documents;
}

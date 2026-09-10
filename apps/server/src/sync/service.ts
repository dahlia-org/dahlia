import { transcriptCheckpoint, waitForTranscript } from "./transcript-checkpoint";
import { uuidSchema, transcriptChunkSchema, SCREENSHOT_DELETE_BATCH_SIZE, STORAGE_OPERATION_CONCURRENCY, QUERY_EMBEDDING_DEADLINE_MS, QUERY_EMBEDDING_CONCURRENCY, permissionPrincipalSchema, SYNC_READ_PAGE_SIZE, TRANSCRIPT_READ_PAGE_SIZE, meetingCursorSchema, screenshotCursorSchema, transcriptCursorSchema, uuidV7Schema, transactionSchema, transactionDataSchemas, SYNC_CHANGE_PAGE_SIZE } from "./schemas";
import type { GeneratedTranscript } from "../summary/transcription";
import { conditionalRead } from "../storage/http-read";
import { SummaryError, type SummaryJob, type SummaryGenerationResult, type SummaryMethod } from "../summary/model";
import { RECORDING_MAX_BYTES, recordingSourceSchema, recordingStorageKey, recordingContentURL, recordingResponse } from "../recordings/model";
import { z } from "zod";
import { searchRequestSchema, searchSnippet, type SearchHit, type SearchResults } from "../search/model";
import { uuidV7 } from "../id";
import { imageAnalysisSchema, type ImageAnalysisInput, type ImageAnalysis } from "../image-analysis/model";

import type { Identity } from "../auth/identity";
import { MAX_FILE_BYTES } from "../config";
import { ObjectStorageError, type StorageReadMethod, type ObjectStorage } from "../storage/storage";
import { RequestError, boundedUploadBody, parseUpload, type ParsedUpload } from "../storage/upload";
import { sha256, sha256Passthrough, sha256Stream } from "../storage/sha256";
import {
  createIntlSearchTokenizer,
  parseSearchQuery,
  SearchQueryError,
  type SearchQuery,
  type SearchTokenizer,
} from "../search/tokenizer";
import { summarySearchableText } from "../search/summary";
import { meetingSearchText, screenshotSearchText } from "../search/document";
import type { SearchEmbedder } from "../search/embedding";
import type {
  IdentitySyncStore,
  MeetingSyncStore,
  SyncSearchQuery,
  SyncHistoryTarget,
  SyncTransaction,
  VaultPrincipalType,
} from "./types";
import { decodeSyncCursor, encodeSyncCursor, SYNC_SNAPSHOT_ENTITIES, SyncTransactionError } from "./store";
import { fileUploadSchema, filePatchSchema, fileResponse, fileStorageKey, fileVariantKey, imageContentTypes, type FileRecord } from "../files/model";
import { SCREENSHOT_VARIANTS, screenshotVariantKey, type ScreenshotTransformer, type ScreenshotVariant } from "./screenshot-variants";
import { metadataRecord, readTextContent, TEXT_CONTENT_VERSION } from "./text-content";

function missingMeetingConflict(meetingId: string): SyncTransactionError {
  return new SyncTransactionError(409, "revision_conflict", [{
    entity: "meeting",
    id: meetingId,
    clientBaseRevision: null,
    serverRevision: null,
    record: null,
  }]);
}

export class MeetingSyncService {
  private readonly activeQueryEmbeddingUsers = new Set<string>();
  private readonly storageOperations = new Map<string, Promise<void>>();
  private readonly storageOperationWaiters: Array<() => void> = [];
  private activeStorageOperations = 0;
  private storageDeleteDrain?: Promise<void>;
  private storageMaintenance?: Promise<void>;
  private storageDeleteRetry?: ReturnType<typeof setTimeout>;
  private readonly variantJobs = new Map<string, Promise<void>>();
  private readonly variantWaiters: Array<() => void> = [];
  private activeVariants = 0;

  constructor(
    private readonly store: MeetingSyncStore,
    private readonly storage?: ObjectStorage,
    private readonly tokenizer: SearchTokenizer = createIntlSearchTokenizer(),
    private readonly embedder?: SearchEmbedder,
    private readonly screenshotTransformer?: ScreenshotTransformer,
    private readonly fileStorageRoot?: string,
    private readonly automaticStorageMaintenance = true,
  ) {
    if (storage) {
      this.scheduleStorageDeletes();
    }
  }

  parseId(value: string): string {
    if (value !== value.toLowerCase()) throw new RequestError(400, "invalid_sync_id");
    const parsed = uuidSchema.safeParse(value);
    if (!parsed.success) throw new RequestError(400, "invalid_sync_id");
    return parsed.data;
  }

  parsePermissionPrincipal(value: string): string {
    const parsed = permissionPrincipalSchema.safeParse(value);
    if (!parsed.success) throw new RequestError(400, "invalid_sync_share_target");
    return parsed.data;
  }

  async vaultTransferAudience(identity: Identity, sourceVaultId: string, destinationVaultId: string) {
    return this.store.withIdentity(identity, (scoped) => scoped.vaultTransferAudience(sourceVaultId, destinationVaultId));
  }

  async transferVault(identity: Identity, sourceVaultId: string, key: string | undefined, body: unknown) {
    this.requireWritableIdentity(identity);
    const idempotencyKey = uuidV7Schema.safeParse(key);
    const parsed = z.object({ destinationVaultId: uuidSchema, sourceRevision: z.number().int().positive(),
      destinationRevision: z.number().int().positive(), audienceHash: z.string().regex(/^[0-9a-f]{64}$/) }).strict().safeParse(body);
    if (!idempotencyKey.success || !parsed.success) throw new RequestError(400, "invalid_vault_transfer");
    const requestHash = await sha256(canonicalJson({ sourceVaultId, ...parsed.data }));
    const result = await this.store.withIdentity(identity, (scoped) => scoped.transferVault({
      sourceVaultId, ...parsed.data, idempotencyKey: idempotencyKey.data, requestHash,
    }));
    return { id: result.id, status: "committed" as const, sourceVaultId, destinationVaultId: result.destinationVaultId };
  }

  async getVaultRelocations(identity: Identity, vaultId: string) {
    return this.store.withIdentity(identity, (scoped) => scoped.getVaultRelocations(vaultId));
  }

  async resolveTransaction(identity: Identity, body: unknown) {
    this.requireWritableIdentity(identity);
    const transaction = await normalizeTransaction(body);
    return this.store.withIdentity(identity, async (scoped) =>
      await scoped.resolveTransaction(transaction) ?? { id: transaction.id, status: "unknown" as const },
    );
  }

  async completeSummary(identity: Identity, job: SummaryJob, result: SummaryGenerationResult, method: SummaryMethod): Promise<boolean> {
    this.requireWritableIdentity(identity);
    const { transcript, ...document } = result;
    return this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(job.vaultId);
      if ((await scoped.getVault(job.vaultId))?.role !== "owner") throw new SummaryError("summary_meeting_unavailable");
      const meeting = await scoped.getMeeting(job.vaultId, job.meetingId);
      if (!meeting) throw new SummaryError("summary_meeting_unavailable");
      if ((meeting.summaryRevision ?? 0) !== job.summaryRevision) throw new SummaryError("summary_conflict");
      if (await method.version(scoped, job.vaultId, job.meetingId, job.input) !== job.inputVersion) throw new SummaryError("summary_input_changed");
      const transcriptOperation = transcript ? await this.stageSummaryTranscript(scoped, job, transcript) : undefined;
      const summaryDocument = JSON.stringify(document);
      const transaction = await normalizeTransaction({
        schemaVersion: 2, id: job.id, vaultId: job.vaultId, createdAt: job.createdAt.toISOString(),
        operations: [
          ...(transcriptOperation ? [transcriptOperation.operation] : []),
          { id: uuidV7(), entity: "meeting", action: "update", entityId: job.meetingId, baseRevision: meeting.revision,
            data: { projectId: meeting.projectId, name: document.title, description: document.description,
              status: meeting.status, duration: meeting.duration, recordingStartedAt: meeting.recordingStartedAt?.toISOString() ?? null,
              updatedAt: new Date().toISOString() } },
          { id: uuidV7(), entity: "summary", action: "upsert", entityId: job.meetingId,
            baseRevision: job.summaryRevision, data: { title: document.title, document: summaryDocument, createdAt: job.createdAt.toISOString() } },
        ],
      });
      const projection = meetingSearchText(this.tokenizer, document.title, document.description, summaryDocument);
      for (const operation of transaction.operations.filter((operation) => operation.entity !== "transcript")) Object.assign(operation.data!, {
        ...projection,
        embeddingContentHash: await embeddingContentHash(projection.searchText),
      });
      return scoped.completeSummaryJob(job, transaction);
    });
  }

  async saveSummaryTranscript(identity: Identity, job: SummaryJob, transcript: GeneratedTranscript, method: SummaryMethod) {
    this.requireWritableIdentity(identity);
    return this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(job.vaultId);
      if ((await scoped.getVault(job.vaultId))?.role !== "owner") throw new SummaryError("summary_meeting_unavailable");
      if (await method.version(scoped, job.vaultId, job.meetingId, job.input) !== job.inputVersion) throw new SummaryError("summary_input_changed");
      const staged = await this.stageSummaryTranscript(scoped, job, transcript);
      const transaction = await normalizeTransaction({ schemaVersion: 2, id: uuidV7(), vaultId: job.vaultId,
        createdAt: new Date().toISOString(), operations: [staged.operation] });
      return scoped.completeSummaryTranscript(job, transaction, staged.transcriptId);
    });
  }

  private async stageSummaryTranscript(scoped: IdentitySyncStore, job: SummaryJob, transcript: GeneratedTranscript) {
    const meeting = await scoped.getMeeting(job.vaultId, job.meetingId);
    if (!meeting || job.transcriptRevision === null || job.transcriptRevision === undefined
      || (meeting.transcriptRevision ?? 0) !== job.transcriptRevision) throw new SummaryError("summary_transcript_conflict");
    const patchId = uuidV7();
    const transcriptId = uuidV7();
    const chunks: Array<{ index: number; sha256: string; segmentCount: number; deletionCount: number }> = [];
    for (let offset = 0; offset < transcript.segments.length; offset += 500) {
      const index = chunks.length;
      const payload = { segments: transcript.segments.slice(offset, offset + 500).map((segment) => ({ ...segment,
        startedAt: segment.startedAt.toISOString(), endedAt: segment.endedAt?.toISOString() ?? null,
        createdAt: segment.createdAt?.toISOString() ?? null })), deletions: [] };
      const parsed = transcriptChunkSchema.parse(payload);
      const hash = await sha256(JSON.stringify(payload));
      if (!await scoped.putTranscriptChunk(job.vaultId, job.meetingId, patchId, index, hash, parsed.segments, parsed.deletions)) {
        throw new SummaryError("summary_transcript_save_failed", true);
      }
      chunks.push({ index, sha256: hash, segmentCount: parsed.segments.length, deletionCount: 0 });
    }
    return { transcriptId, operation: { id: patchId, entity: "transcript", action: "patch", entityId: job.meetingId,
      baseRevision: job.transcriptRevision, data: { mode: "replace", patchId, segmentCount: transcript.segments.length,
        deletionCount: 0, chunks, transcript: { id: transcriptId, startedAt: transcript.startedAt.toISOString(),
          endedAt: transcript.endedAt.toISOString(), metadata: transcript.metadata } } } };
  }

  async completeImageAnalysis(identity: Identity, input: ImageAnalysisInput, output: ImageAnalysis): Promise<boolean> {
    const analysis = imageAnalysisSchema.parse(output);
    const metadata = {
      ...input.file.metadata,
      ocr_text: input.file.metadata.ocr_text ?? analysis.ocr_text,
      caption: input.file.metadata.caption?.trim() ? input.file.metadata.caption : analysis.caption,
    };
    const transaction = await normalizeTransaction({
      schemaVersion: 2, id: uuidV7(), vaultId: input.vaultId, createdAt: new Date().toISOString(),
      operations: [{
        id: uuidV7(), entity: "file", action: "upsert", entityId: input.fileId,
        baseRevision: input.file.revision, data: { checksum: input.file.checksum, metadata: { ocrText: metadata.ocr_text, caption: metadata.caption } },
      }],
    });
    Object.assign(transaction.operations[0]!.data!, await this.fileSearchData(metadata));
    return this.store.withIdentity(identity, (scoped) => scoped.completeImageAnalysis(input, transaction));
  }

  private async fileSearchData(metadata: Partial<FileRecord["metadata"]>) {
    const projection = screenshotSearchText(this.tokenizer, metadata.ocr_text, metadata.caption);
    return { ...projection, embeddingContentHash: await embeddingContentHash(projection.searchText) };
  }

  async commitTransaction(identity: Identity, body: unknown) {
    this.requireWritableIdentity(identity);
    const normalized = await normalizeTransaction(body);
    const { operations, requestHash } = normalized;
    let response: Awaited<ReturnType<IdentitySyncStore["commitTransaction"]>>;
    try {
      response = await this.store.withIdentity(identity, async (scoped) => {
        const receipt = await scoped.resolveTransaction(normalized);
        if (receipt?.receipt === "compact") throw new SyncTransactionError(410, "transaction_receipt_expired");
        if (receipt) return receipt;
        const meetings = new Map<string, Awaited<ReturnType<IdentitySyncStore["getMeeting"]>>>();
        const prepared = [] as SyncTransaction["operations"];
        const fileMetadata = new Map<string, FileRecord["metadata"]>();
        for (const operation of operations) {
          const data = { ...(operation.data ?? {}) };
          if ((operation.entity === "meeting" && operation.action !== "delete") || operation.entity === "summary") {
            let meeting = meetings.get(operation.entityId);
            if (meeting === undefined) {
              meeting = operation.entity === "meeting" && operation.action === "create"
                ? null
                : await scoped.getMeeting(normalized.vaultId, operation.entityId);
            }
            const name = operation.entity === "meeting" && typeof data.name === "string" ? data.name : meeting?.name ?? "";
            const description = operation.entity === "meeting" && typeof data.description === "string"
              ? data.description
              : meeting?.description ?? "";
            const summaryDocument = operation.entity === "summary"
              ? operation.action === "upsert" ? String(data.document) : null
              : meeting?.summaryDocument ?? null;
            const projection = meetingSearchText(this.tokenizer, name, description, summaryDocument);
            Object.assign(data, {
              ...projection,
              embeddingContentHash: await embeddingContentHash(projection.searchText),
            });
            meetings.set(operation.entityId, {
              ...(meeting ?? {}),
              meetingId: operation.entityId,
              vaultId: normalized.vaultId,
              projectId: operation.entity === "meeting" ? data.projectId as string | null : meeting?.projectId ?? null,
              name,
              description,
              status: operation.entity === "meeting" ? String(data.status) : meeting?.status ?? "",
              duration: operation.entity === "meeting" ? data.duration as number | null : meeting?.duration ?? null,
              recordingStartedAt: operation.entity === "meeting" ? data.recordingStartedAt as Date | null : meeting?.recordingStartedAt ?? null,
              createdAt: operation.entity === "meeting" && operation.action === "create" ? data.createdAt as Date : meeting?.createdAt ?? normalized.createdAt,
              updatedAt: operation.entity === "meeting" ? data.updatedAt as Date : meeting?.updatedAt ?? normalized.createdAt,
              summaryTitle: operation.entity === "summary" && operation.action === "upsert" ? String(data.title) : operation.action === "delete" ? null : meeting?.summaryTitle ?? null,
              summaryDocument,
              summaryCreatedAt: operation.entity === "summary" && operation.action === "upsert" ? data.createdAt as Date : operation.action === "delete" ? null : meeting?.summaryCreatedAt ?? null,
            });
          } else if (["file", "meeting_attachment"].includes(operation.entity) && operation.action === "upsert") {
            const fileId = operation.entity === "file" ? operation.entityId : String(data.fileId);
            const file = fileMetadata.get(fileId) ?? (await scoped.getFile(fileId))?.metadata;
            const metadata = { ...file, ...(operation.entity === "file" ? data.metadata as object : {}) };
            if (metadata.source) fileMetadata.set(fileId, metadata as FileRecord["metadata"]);
            Object.assign(data, await this.fileSearchData(metadata));
          }
          prepared.push({ ...operation, data });
        }
        return scoped.commitTransaction({ ...normalized, operations: prepared, requestHash });
      });
    } catch (error) {
      if (error instanceof SyncTransactionError
        && error.status >= 400 && error.status < 500
        && ![408, 425, 429].includes(error.status)) {
        try {
          await this.store.withIdentity(identity, async (scoped) => {
            for (const operation of operations) {
              if (operation.entity === "transcript" && operation.action === "patch") {
                await scoped.deleteTranscriptPatch(normalized.vaultId, operation.entityId, operation.id);
              }
            }
          });
        } catch {
          // A later upload removes expired staging rows. File reservations remain retryable for 24 hours.
        }
      }
      throw error;
    }
    this.scheduleStorageDeletes();
    return response;
  }

  runStorageMaintenance(): Promise<void> {
    return this.storageMaintenance ??= this.maintainStorage().finally(() => { this.storageMaintenance = undefined; });
  }

  private async maintainStorage(): Promise<void> {
    if (!this.storage) return;
    let after: SyncHistoryTarget | undefined;
    const before = new Date(Date.now() - 86_400_000);
    for (;;) {
      const targets = await this.store.listHistoryTargets(after);
      if (!targets.length) break;
      for (const target of targets) {
        await this.store.withIdentity({
          userId: target.ownerUserId, workspaceId: `personal:${target.ownerUserId}`, source: "header",
        }, (scoped) => scoped.expireRecordingUploads(target.vaultId, before));
      }
      after = targets.at(-1);
    }
    await this.storageDeleteDrain;
    this.scheduleStorageDeletes(true);
    await this.storageDeleteDrain;
  }

  private scheduleStorageDeletes(explicit = false): void {
    if (!this.automaticStorageMaintenance && !explicit) return;
    this.storageDeleteDrain ??= this.drainStorageDeletes()
      .catch(() => undefined)
      .finally(() => {
        this.storageDeleteDrain = undefined;
        this.scheduleStorageDeleteRetry();
      });
  }

  private scheduleStorageDeleteRetry(): void {
    if (!this.automaticStorageMaintenance) return;
    if (this.storageDeleteRetry) return;
    this.storageDeleteRetry = setTimeout(() => {
      this.storageDeleteRetry = undefined;
      void this.runStorageMaintenance().catch(() => undefined).finally(() => this.scheduleStorageDeleteRetry());
    }, 60_000);
    this.storageDeleteRetry.unref?.();
  }

  private async drainStorageDeletes(): Promise<void> {
    if (!this.storage) return;
    while (true) {
      const claims = await this.store.claimStorageDeletes(SCREENSHOT_DELETE_BATCH_SIZE);
      if (claims.length === 0) return;
      for (const claim of claims) {
        try {
          await this.withStorageOperation(claim.storageKey, () => this.store.withStorageKeyLock(
            claim.storageKey,
            async () => {
              if (!await this.store.isStorageDeleteClaimCurrent(claim)) return;
              for (const variant of (claim.storageKey.endsWith("/original") ? Object.keys(SCREENSHOT_VARIANTS) : []) as ScreenshotVariant[]) {
                await this.storageCall(() => this.storage!.delete(screenshotVariantKey(claim.storageKey, variant)));
              }
              await this.storageCall(() => this.storage!.delete(claim.storageKey));
              await this.store.completeStorageDelete(claim);
            },
          ));
        } catch (error) {
          await this.store.failStorageDelete(
            claim,
            error instanceof ObjectStorageError ? error.code : "object_storage_unavailable",
          );
          this.scheduleStorageDeleteRetry();
        }
      }
    }
  }

  async listChanges(identity: Identity, vaultId: string, cursor?: string, highWaterCursor?: string) {
    const after = cursor ? decodeSyncCursor(cursor) : 0;
    const suppliedHighWater = highWaterCursor ? decodeSyncCursor(highWaterCursor) : undefined;
    if (suppliedHighWater !== undefined && suppliedHighWater < after) {
      throw new SyncTransactionError(400, "invalid_sync_cursor");
    }
    const { rows, highWater } = await this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      await scoped.expireRecordingUploads(vaultId, new Date(Date.now() - 86_400_000));
      const highWater = suppliedHighWater ?? await scoped.latestChangeSequence(vaultId);
      const rows = await scoped.listChanges(vaultId, after, highWater, SYNC_CHANGE_PAGE_SIZE + 1);
      for (const row of rows) {
        row.record = (await metadataRecord({ entity: row.entity, id: row.entityId, revision: row.revision, record: row.record }, scoped, vaultId)).record;
      }
      return { rows, highWater };
    });
    this.scheduleStorageDeletes();
    const items = rows.slice(0, SYNC_CHANGE_PAGE_SIZE);
    const last = items.at(-1);
    return {
      items,
      cursor: encodeSyncCursor(rows.length > SYNC_CHANGE_PAGE_SIZE ? last!.sequence : highWater),
      highWaterCursor: encodeSyncCursor(highWater),
      hasMore: rows.length > SYNC_CHANGE_PAGE_SIZE,
    };
  }

  async listSnapshot(identity: Identity, vaultId: string, cursor?: string, startCursor?: string) {
    const position = cursor ? z.tuple([z.enum(SYNC_SNAPSHOT_ENTITIES), uuidSchema]).safeParse(cursor.split(",")) : undefined;
    if ((position && !position.success) || (cursor && !startCursor)) {
      throw new SyncTransactionError(400, "invalid_snapshot_cursor");
    }
    const suppliedStart = startCursor ? decodeSyncCursor(startCursor) : undefined;
    return this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      if (!await scoped.getVault(vaultId)) throw new SyncTransactionError(404, "vault_not_found");
      const latest = await scoped.latestChangeSequence(vaultId);
      const start = suppliedStart ?? latest;
      if (start > latest) throw new SyncTransactionError(400, "invalid_snapshot_cursor");
      await scoped.assertCursorAvailable(vaultId, start);
      const { items, hasMore } = await scoped.listSnapshot(
        vaultId,
        position?.success ? { entity: position.data[0], id: position.data[1] } : undefined,
        SYNC_CHANGE_PAGE_SIZE,
      );
      const last = items.at(-1);
      return {
        items: await Promise.all(items.map((item) => metadataRecord(item, scoped, vaultId))),
        startCursor: encodeSyncCursor(start),
        nextCursor: hasMore && last ? `${last.entity},${last.id}` : null,
      };
    });
  }

  async latestSummary(identity: Identity, vaultId: string, meetingId: string, manifest?: string) {
    if (manifest !== undefined && manifest !== "1") throw new SyncTransactionError(400, "invalid_content_request");
    return this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      const meeting = await scoped.getMeeting(vaultId, meetingId);
      if (!meeting) throw new SyncTransactionError(404, "meeting_not_found");
      return readTextContent(scoped, vaultId, "summary", meetingId, meeting.summaryRevision ?? 0, manifest === "1");
    });
  }

  async summaryVersions(identity: Identity, vaultId: string, meetingId: string, cursor?: string, limitValue?: string) {
    const integer = z.string().regex(/^\d+$/).transform(Number).pipe(z.number().int().nonnegative().max(2147483647));
    const parsed = z.object({ cursor: integer.optional(), limit: integer.pipe(z.number().min(1).max(100)).default(20) }).safeParse({ cursor, limit: limitValue });
    if (!parsed.success) throw new SyncTransactionError(400, "invalid_summary_versions_request");
    return this.store.withIdentity(identity, async (scoped) => {
      if (!await scoped.getMeeting(vaultId, meetingId)) throw new SyncTransactionError(404, "meeting_not_found");
      const rows = await scoped.listSummaryVersions(vaultId, meetingId, parsed.data.limit + 1, parsed.data.cursor);
      const items = rows.slice(0, parsed.data.limit);
      return { items, nextCursor: rows.length > parsed.data.limit ? String(items.at(-1)!.version) : null };
    });
  }

  async summaryVersion(identity: Identity, vaultId: string, meetingId: string, version: string) {
    const versionNumber = Number(version);
    if (!/^\d+$/.test(version) || !Number.isSafeInteger(versionNumber) || versionNumber > 2147483647) {
      throw new SyncTransactionError(400, "invalid_summary_version");
    }
    return this.store.withIdentity(identity, async (scoped) => {
      if (!await scoped.getMeeting(vaultId, meetingId)) throw new SyncTransactionError(404, "meeting_not_found");
      const version = await scoped.getSummaryVersion(vaultId, meetingId, versionNumber);
      if (!version) throw new SyncTransactionError(404, "summary_version_not_found");
      return version;
    });
  }

  async transcriptVersions(identity: Identity, vaultId: string, meetingId: string, cursor?: string, limitValue?: string) {
    const integer = z.string().regex(/^\d+$/).transform(Number).pipe(z.number().int().nonnegative().max(2147483647));
    const parsed = z.object({ cursor: integer.optional(), limit: integer.pipe(z.number().min(1).max(100)).default(20) }).safeParse({ cursor, limit: limitValue });
    if (!parsed.success) throw new SyncTransactionError(400, "invalid_transcript_versions_request");
    return this.store.withIdentity(identity, async (scoped) => {
      if (!await scoped.getMeeting(vaultId, meetingId)) throw new SyncTransactionError(404, "meeting_not_found");
      const rows = await scoped.listTranscriptVersions(vaultId, meetingId, parsed.data.limit + 1, parsed.data.cursor);
      const items = rows.slice(0, parsed.data.limit);
      return { items, nextCursor: rows.length > parsed.data.limit ? String(items.at(-1)!.version) : null };
    });
  }

  async transcriptContent(identity: Identity, vaultId: string, meetingId: string, version: string,
    manifest?: string, cursor?: string) {
    const number = Number(version);
    if ((version !== "latest" && (!/^\d+$/.test(version) || !Number.isSafeInteger(number) || number < 1 || number > 2147483647))
      || (manifest !== undefined && manifest !== "1") || (cursor && manifest)) {
      throw new SyncTransactionError(400, "invalid_transcript_request");
    }
    const after = cursor ? this.parseTranscriptCursor(cursor) : undefined;
    return this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      const meeting = await scoped.getMeeting(vaultId, meetingId);
      if (!meeting) throw new SyncTransactionError(404, "meeting_not_found");
      return readTextContent(scoped, vaultId, "transcript", meetingId, meeting.transcriptRevision ?? 0,
        manifest === "1", after, version === "latest" ? undefined : number);
    });
  }

  async searchAll(identity: Identity, body: unknown, signal?: AbortSignal): Promise<SearchResults> {
    const parsed = searchRequestSchema.safeParse(body);
    if (!parsed.success) throw new RequestError(400, "invalid_search_request");
    const { vaultId, query, kind, limit, from, to, projectId } = parsed.data;
    const allowed = await this.store.withIdentity(identity, (scoped) => scoped.getVault(vaultId));
    if (!allowed) throw new RequestError(404, "vault_not_found");
    const hits = await this.search(identity, this.parseSearchQuery(query), async (scoped, prepared) => {
      if (!await scoped.getVault(vaultId)) throw new RequestError(404, "vault_not_found");
      const projects = await scoped.listProjects(vaultId);
      const included = projectId ? new Set([projectId]) : undefined;
      if (included) {
        if (!projects.some((project) => project.projectId === projectId)) throw new RequestError(404, "project_not_found");
        for (let previous = -1; previous !== included.size;) {
          previous = included.size;
          for (const project of projects) if (project.parentProjectId && included.has(project.parentProjectId)) included.add(project.projectId);
        }
      }
      const filters = { from, to, projectIds: included ? [...included] : undefined };
      // Each kind owns its FTS ranks; combining them would shift screenshot ranks.
      const search = prepared ? { ...prepared, ftsCandidateIds: undefined } : undefined;
      const [meetings, screenshots, activity] = await Promise.all([
        !kind || kind === "meeting" ? scoped.listMeetings(vaultId, search, 100, undefined, undefined, undefined, filters) : [],
        !kind || kind === "screenshot" ? scoped.listScreenshots(vaultId, undefined, search, 100, undefined, filters) : [],
        !kind || kind === "project" ? scoped.searchProjectActivity(vaultId, filters) : [],
      ]);
      const parents = screenshots.length ? await scoped.listMeetings(vaultId, undefined, 100, undefined, undefined, undefined,
        { meetingIds: [...new Set(screenshots.map((item) => item.meetingId))] }) : [];
      const byMeeting = new Map(parents.map((meeting) => [meeting.meetingId, meeting]));
      const byProject = new Map(projects.map((project) => [project.projectId, project]));
      const projectFields = (id: string | null | undefined) => id ? { projectId: id, projectPath: byProject.get(id)?.path } : {};
      const result: SearchHit[] = meetings.map((meeting) => ({
        kind: "meeting", id: meeting.meetingId, meetingId: meeting.meetingId, title: meeting.name,
        date: meeting.createdAt.toISOString(), ...projectFields(meeting.projectId),
        snippet: searchSnippet([meeting.description, summarySearchableText(meeting.summaryDocument)].filter(Boolean).join("\n"), query),
      }));
      for (const screenshot of screenshots) {
        const meeting = byMeeting.get(screenshot.meetingId);
        if (!meeting) continue;
        result.push({ kind: "screenshot", id: screenshot.screenshotId, meetingId: screenshot.meetingId,
          title: meeting.name, date: screenshot.capturedAt.toISOString(), ...projectFields(meeting.projectId),
          snippet: searchSnippet([screenshot.caption, screenshot.ocrText].filter(Boolean).join("\n"), query), fileId: screenshot.fileId });
      }
      if (!kind || kind === "project") {
        const recent = new Map(activity.filter((item) => item.projectId).map((item) => [item.projectId!, item.updatedAt]));
        for (const project of projects) {
          const date = recent.get(project.projectId);
          let parentId = project.parentProjectId;
          const seen = new Set<string>();
          while (date && parentId && !seen.has(parentId)) {
            seen.add(parentId);
            if ((recent.get(parentId) ?? "") < date) recent.set(parentId, date);
            parentId = byProject.get(parentId)?.parentProjectId ?? null;
          }
        }
        const terms = query.normalize("NFKC").toLocaleLowerCase().split(/\s+/).filter(Boolean);
        const matches = projects.filter((project) => (!included || included.has(project.projectId))
          && (!(from || to) || recent.has(project.projectId))
          && terms.every((term) => project.path.normalize("NFKC").toLocaleLowerCase().includes(term)))
          .sort((a, b) => (recent.get(b.projectId) ?? "").localeCompare(recent.get(a.projectId) ?? "")
            || a.path.localeCompare(b.path) || a.projectId.localeCompare(b.projectId));
        result.push(...matches.slice(0, 101).map((project): SearchHit => ({
          kind: "project", id: project.projectId, title: project.name, projectId: project.projectId,
          projectPath: project.path, date: recent.get(project.projectId) ?? project.createdAt.toISOString(),
          snippet: "", meetingCount: project.subtreeMeetingCount,
        })));
      }
      return result;
    }, (hit) => hit.id, signal);
    if (!await this.store.withIdentity(identity, (scoped) => scoped.getVault(vaultId))) throw new RequestError(404, "vault_not_found");
    const meetings = hits.filter((hit) => hit.kind === "meeting");
    const screenshots = hits.filter((hit) => hit.kind === "screenshot");
    const projects = hits.filter((hit) => hit.kind === "project");
    return {
      vaultId,
      meetings: meetings.slice(0, limit),
      screenshots: screenshots.slice(0, limit),
      projects: projects.slice(0, limit),
      limited: {
        meeting: meetings.length > limit || meetings.length === 100,
        screenshot: screenshots.length > limit || screenshots.length === 100,
        project: projects.length > limit,
      },
    };
  }

  async searchText(identity: Identity, vaultId: string, queryValue?: string, kindValue?: string, cursor?: string, limitValue?: string) {
    const limit = limitValue === undefined ? 200 : Number(limitValue);
    if (!Number.isInteger(limit) || limit < 1 || limit > 200) throw new SyncTransactionError(400, "invalid_search_limit");
    const query = this.parseSearchQuery(queryValue);
    if (!query || (kindValue !== "meeting" && kindValue !== "screenshot")) throw new SyncTransactionError(400, "invalid_search_request");
    let parsedCursor: unknown;
    try { parsedCursor = cursor ? JSON.parse(cursor) : undefined; }
    catch { throw new SyncTransactionError(400, "invalid_search_cursor"); }
    const position = cursor ? z.tuple([z.string(), z.string(), z.string(), z.number().int().nonnegative(), z.number().int().nonnegative()])
      .safeParse(parsedCursor) : undefined;
    if (position && (!position.success || position.data[0] !== vaultId || position.data[1] !== kindValue || position.data[2] !== queryValue)) {
      throw new SyncTransactionError(400, "invalid_search_cursor");
    }
    return this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      if (!await scoped.getVault(vaultId)) throw new SyncTransactionError(404, "vault_not_found");
      const revision = await scoped.latestChangeSequence(vaultId);
      if (position?.success && revision !== position.data[3]) throw new SyncTransactionError(409, "search_revision_changed");
      const offset = position?.success ? position.data[4] : 0;
      const rows = await scoped.searchTextPage(vaultId, query, kindValue, offset, limit + 1);
      return { version: TEXT_CONTENT_VERSION, scope: "server", items: rows.slice(0, limit),
        nextCursor: rows.length > limit ? JSON.stringify([vaultId, kindValue, queryValue, revision, offset + limit]) : null };
    });
  }

  latestCursor(identity: Identity) {
    return this.store.withIdentity(identity, async (scoped) => encodeSyncCursor(await scoped.latestChangeSequence()));
  }

  async putTranscriptChunk(
    identity: Identity,
    meetingId: string,
    patchId: string,
    chunkIndex: number,
    contentHash: string,
    body: unknown,
  ): Promise<void> {
    const parsed = transcriptChunkSchema.safeParse(body);
    if (!parsed.success) throw new RequestError(400, "invalid_transcript_chunk");
    const accepted = await this.store.withIdentity(identity, async (scoped) => {
      const vaultId = await scoped.resolveEntityVault("meeting", meetingId);
      return vaultId ? scoped.putTranscriptChunk(vaultId, meetingId, patchId, chunkIndex,
        contentHash, parsed.data.segments, parsed.data.deletions) : false;
    });
    if (!accepted) throw missingMeetingConflict(meetingId);
  }

  async putRecordingContent(identity: Identity, meetingId: string, sessionIdValue: string, sourceValue: string, request: Request) {
    this.requireWritableIdentity(identity);
    const sessionId = uuidV7Schema.safeParse(sessionIdValue);
    const parsedSource = recordingSourceSchema.safeParse(sourceValue);
    if (!sessionId.success || !parsedSource.success) throw new RequestError(400, "invalid_recording_target");
    const source = parsedSource.data;
    const upload = parseUpload(request, RECORDING_MAX_BYTES);
    if (upload.contentType !== "audio/mp4" || upload.contentLength < 16 || !request.body) {
      throw new RequestError(415, "invalid_recording_format");
    }
    this.requireStorage();
    const vaultId = await this.store.withIdentity(identity, async (scoped) => {
      const vaultId = await scoped.resolveEntityVault("meeting", meetingId);
      if (!vaultId || !await scoped.ensureUploadTarget(vaultId, meetingId)) throw new RequestError(404, "meeting_not_found");
      await scoped.expireRecordingUploads(vaultId, new Date(Date.now() - 86_400_000));
      return vaultId;
    });
    // Expiration must commit even when reservation waits for the queued physical deletion.
    this.scheduleStorageDeletes();
    const reservation = await this.store.withIdentity(identity, (scoped) =>
      scoped.reserveRecording(vaultId, meetingId, sessionId.data, source));
    const key = recordingStorageKey(reservation, source);
    const generation = reservation.audio[source]!.generation;
    return this.withStorageOperation(key, () => this.store.withStorageKeyLock(key, async () => {
      const record = await this.store.withIdentity(identity, (scoped) => scoped.getRecording(meetingId, reservation.number, true));
      const previous = record?.audio[source];
      if (!record || previous?.generation !== generation) throw new RequestError(409, "recording_upload_expired");
      if (await this.store.hasStorageDelete(key)) throw new RequestError(503, "recording_storage_delete_pending");
      let prefixLength = 0;
      const prefix = new Uint8Array(12);
      const bounded = boundedUploadBody(request.body, upload.contentLength, "recording_size_mismatch", (chunk) => {
        const part = chunk.subarray(0, prefix.length - prefixLength);
        prefix.set(part, prefixLength);
        prefixLength += part.length;
        if (prefixLength === 12 && (String.fromCharCode(...prefix.subarray(4, 8)) !== "ftyp"
          || new DataView(prefix.buffer).getUint32(0) < 16)) throw new RequestError(415, "invalid_recording_format");
      });
      if (previous.uploadedAt) {
        const checksum = `SHA-256:${await sha256Stream(bounded)}`;
        if (previous.size !== upload.contentLength || previous.checksum !== checksum) throw new RequestError(409, "recording_content_conflict");
        return { created: false, record: { id: record.number, source, contentType: previous.content_type,
          size: previous.size, checksum, revision: record.revision || null, contentUrl: recordingContentURL(record, source) } };
      }
      return this.storeUpload(key, bounded, upload, request.signal, async (checksum) => {
        const completed = await this.store.withIdentity(identity, (scoped) =>
          scoped.markRecordingUploaded(record.sessionId, source, generation, upload.contentLength, checksum));
        if (!completed) throw new RequestError(409, "recording_upload_expired");
        return { created: true, record: { id: completed.number, source, contentType: upload.contentType,
          size: upload.contentLength, checksum, revision: completed.revision || null, contentUrl: recordingContentURL(completed, source) } };
      });
    }));
  }

  async listRecordings(identity: Identity, meetingId: string, cursor?: string) {
    const after = cursor === undefined ? 0 : Number(cursor);
    if (!Number.isSafeInteger(after) || after < 0) throw new RequestError(400, "invalid_recording_cursor");
    const records = await this.store.withIdentity(identity, async (scoped) => {
      if (!await scoped.resolveEntityVault("meeting", meetingId)) throw new RequestError(404, "meeting_not_found");
      return scoped.listRecordings(meetingId, after, SYNC_READ_PAGE_SIZE + 1);
    });
    const items = records.slice(0, SYNC_READ_PAGE_SIZE);
    return { items: items.map((record) => recordingResponse(record)),
      nextCursor: records.length > SYNC_READ_PAGE_SIZE ? String(items[items.length - 1]!.number) : null };
  }

  async recordingContent(identity: Identity, meetingId: string, numberValue: string, sourceValue: string, request: Request) {
    const number = Number(numberValue);
    const parsedSource = recordingSourceSchema.safeParse(sourceValue);
    if (!Number.isSafeInteger(number) || number < 1 || !parsedSource.success) throw new RequestError(400, "invalid_recording_target");
    const source = parsedSource.data;
    const authorize = () => this.store.withIdentity(identity, async (scoped) => {
      if (!await scoped.resolveEntityVault("meeting", meetingId)) throw new RequestError(404, "meeting_not_found");
      const record = await scoped.getRecording(meetingId, number);
      if (!record?.audio[source]?.uploadedAt || (!record.audio[source].active && new Date(record.audio[source].createdAt).getTime() <= Date.now() - 86_400_000) || (!record.audio[source].active && !await scoped.getRecording(meetingId, number, true))) {
        throw new RequestError(404, "recording_not_found");
      }
      return record;
    });
    const initial = await authorize();
    const key = recordingStorageKey(initial, source);
    return this.withStorageOperation(key, () => this.store.withStorageKeyLock(key, async () => {
      const record = await authorize();
      if (await this.store.hasStorageDelete(key)) throw new RequestError(404, "recording_not_found");
      const headers = new Headers({
        "content-type": "audio/mp4", "cache-control": "private, no-store",
        vary: "Authorization, Cookie", "x-content-type-options": "nosniff",
        etag: `"${record.audio[source]!.checksum}"`,
      });
      return conditionalRead(request, request.method as StorageReadMethod, headers, (method, readRequest) =>
        this.storageCall(() => this.requireStorage().read(key, method, readRequest)));

    }));
  }

  async reserveFileUpload(identity: Identity, body: unknown) {
    this.requireWritableIdentity(identity);
    this.requireStorage();
    if (!this.fileStorageRoot) throw new RequestError(503, "file_storage_not_configured");
    const parsed = fileUploadSchema.safeParse(body);
    if (!parsed.success) throw new RequestError(400, "invalid_file_upload");
    const { id: fileId, vaultId, name, contentType, metadata } = parsed.data;
    const key = fileStorageKey(fileId);
    return this.withStorageOperation(key, () => this.store.withStorageKeyLock(key, async () => {
      const now = new Date();
      const result = await this.store.withIdentity(identity, async (scoped) => {
        await scoped.expireFileUploads(vaultId, new Date(now.getTime() - 86_400_000));
        const previous = await scoped.getFile(fileId);
        const file = await scoped.reserveFile({ fileId, vaultId, name, contentType, metadata,
          uri: `${this.fileStorageRoot}/${key}`, offset: 0, size: 0, checksum: "",
          active: false, uploadedAt: null, revision: 0, createdAt: now, updatedAt: now });
        if (!file) throw new RequestError(404, "file_or_vault_not_found");
        if (file.contentType !== contentType || file.name !== name || file.metadata.source !== metadata.source
          || file.metadata.width !== metadata.width || file.metadata.height !== metadata.height) {
          throw new RequestError(409, "file_id_conflict");
        }
        return { file: this.fileMetadata(fileResponse(file)), created: previous === null };
      });
      this.scheduleStorageDeletes();
      return result;
    }));
  }

  async putFileContent(identity: Identity, fileId: string, request: Request) {
    this.requireWritableIdentity(identity);
    this.requireStorage();
    const upload = parseUpload(request, MAX_FILE_BYTES);
    if (upload.contentType !== "application/octet-stream") throw new RequestError(415, "unsupported_media_type");
    const key = fileStorageKey(fileId);
    return this.withStorageOperation(key, () => this.store.withStorageKeyLock(key, async () => {
      const file = await this.store.withIdentity(identity, async (scoped) => {
        const pending = await scoped.getFile(fileId);
        if (!pending || (await scoped.getVault(pending.vaultId))?.role !== "owner") {
          throw new RequestError(404, "file_not_found");
        }
        return pending;
      });
      if (file.uploadedAt && file.size !== upload.contentLength) {
        throw new RequestError(409, "file_id_conflict");
      }
      if (await this.store.hasStorageDelete(key)) throw new RequestError(503, "file_storage_delete_pending");
      const bounded = boundedUploadBody(request.body, upload.contentLength, "file_size_mismatch");
      if (file.uploadedAt) {
        if (`SHA-256:${await sha256Stream(bounded)}` !== file.checksum) throw new RequestError(409, "file_checksum_mismatch");
        return { file: this.fileMetadata(fileResponse(file)), created: false };
      }
      return this.storeUpload(key, bounded, { ...upload, contentType: file.contentType }, request.signal, async (checksum) => {
        const uploaded = await this.store.withIdentity(identity, (scoped) => scoped.markFileUploaded(file, upload.contentLength, checksum));
        if (!uploaded) {
          if (await this.store.hasStorageDelete(key)) throw new RequestError(503, "file_storage_delete_pending");
          throw new RequestError(404, "file_not_found");
        }
        return { file: this.fileMetadata(fileResponse(uploaded)), created: true };
      });
    }));
  }

  // Call under the storage key lock; metadata is published only after the entire body is stored and hashed.
  private async storeUpload<T>(key: string, body: ReadableStream<Uint8Array> | null,
    upload: ParsedUpload, signal: AbortSignal, complete: (checksum: string) => Promise<T>): Promise<T> {
    const storage = this.requireStorage();
    const hashing = sha256Passthrough(body);
    const abort = new AbortController();
    const storing = this.storageCall(() => storage.put(key, hashing.body, upload.contentLength, upload.contentType,
      AbortSignal.any([signal, abort.signal]))).catch(async (error: unknown) => {
      await hashing.cancel(error).catch(() => undefined);
      throw error;
    });
    const digest = hashing.digest.catch((error: unknown) => { abort.abort(error); throw error; });
    try {
      // Settle the write before cleanup or unlocking, including when validation interrupts the stream.
      const [stored, hashed] = await Promise.allSettled([storing, digest]);
      if (hashed.status === "rejected") throw hashed.reason;
      if (stored.status === "rejected") throw stored.reason;
      return await complete(`SHA-256:${hashed.value}`);
    } catch (error) {
      try { await storage.delete(key); } catch {
        await this.store.enqueueStorageDelete(key);
        this.scheduleStorageDeletes();
      }
      throw error;
    }
  }

  async patchFile(identity: Identity, fileId: string, body: unknown) {
    this.requireWritableIdentity(identity);
    const parsed = filePatchSchema.safeParse(body);
    if (!parsed.success) throw new RequestError(400, "invalid_file_patch");
    const file = await this.store.withIdentity(identity, (scoped) => scoped.getFile(fileId));
    if (!file?.active) throw new RequestError(404, "file_not_found");
    const response = await this.commitTransaction(identity, {
      schemaVersion: 2, id: uuidV7(), vaultId: file.vaultId, createdAt: new Date().toISOString(),
      operations: [{ id: uuidV7(), entity: "file", action: "upsert", entityId: fileId,
        baseRevision: parsed.data.baseRevision, data: { checksum: file.checksum, metadata: parsed.data.metadata } }],
    });
    const record = response.records.find((record) => record.entity === "file" && record.id === fileId)!;
    return this.fileMetadata(record.record as ReturnType<typeof fileResponse>);
  }

  async getFile(identity: Identity, fileId: string) {
    const file = await this.store.withIdentity(identity, (scoped) => scoped.getFile(fileId, true));
    if (!file) throw new RequestError(404, "file_not_found");
    const record = this.fileMetadata(fileResponse(file));
    return { ...record, metadata: { ...record.metadata, ocrText: record.metadata.ocrText ?? null, caption: record.metadata.caption ?? null } };
  }

  private fileMetadata(file: ReturnType<typeof fileResponse>) {
    const variants: Record<string, string> = {};
    if (this.screenshotTransformer && imageContentTypes.has(file.contentType)) {
      for (const variant of Object.keys(SCREENSHOT_VARIANTS)) {
        variants[variant] = `/api/v1/files/${file.id}/variants/${variant}`;
      }
    }
    return { ...file, contentUrl: `/api/v1/files/${file.id}/content`, variants };
  }

  async listFiles(identity: Identity, vaultId: string, cursor?: string, meetingId?: string) {
    const after = cursor === undefined ? undefined : this.parseId(cursor);
    return this.store.withIdentity(identity, async (scoped) => {
      if (meetingId) {
        const rows = await scoped.listMeetingAttachments(vaultId, meetingId, after, SYNC_READ_PAGE_SIZE + 1);
        const items = rows.slice(0, SYNC_READ_PAGE_SIZE).map(({ file, ...link }) => ({ ...link, file: this.fileMetadata(fileResponse(file)) }));
        return { items, nextCursor: rows.length > SYNC_READ_PAGE_SIZE ? items.at(-1)!.id : null };
      }
      const rows = await scoped.listFiles(vaultId, after, SYNC_READ_PAGE_SIZE + 1);
      const items = rows.slice(0, SYNC_READ_PAGE_SIZE).map((file) => this.fileMetadata(fileResponse(file)));
      return { items, nextCursor: rows.length > SYNC_READ_PAGE_SIZE ? items.at(-1)!.id : null };
    });
  }

  private async withStorageOperation<T>(storageKey: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.storageOperations.get(storageKey) ?? Promise.resolve();
    let releaseKey!: () => void;
    const current = new Promise<void>((resolve) => { releaseKey = resolve; });
    this.storageOperations.set(storageKey, current);
    await previous;
    await this.acquireStorageOperationSlot();
    try {
      return await operation();
    } finally {
      this.releaseStorageOperationSlot();
      releaseKey();
      if (this.storageOperations.get(storageKey) === current) this.storageOperations.delete(storageKey);
    }
  }

  private async acquireStorageOperationSlot(): Promise<void> {
    if (this.activeStorageOperations < STORAGE_OPERATION_CONCURRENCY) {
      this.activeStorageOperations += 1;
      return;
    }
    await new Promise<void>((resolve) => this.storageOperationWaiters.push(resolve));
  }

  private releaseStorageOperationSlot(): void {
    const next = this.storageOperationWaiters.shift();
    if (next) next();
    else this.activeStorageOperations -= 1;
  }

  async readScreenshot(identity: Identity, vaultId: string, meetingId: string, screenshotId: string,
    method: StorageReadMethod, request: Request): Promise<Response> {
    const image = await this.store.withIdentity(identity, (scoped) => scoped.getScreenshot(vaultId, meetingId, screenshotId, true));
    if (!image) throw new RequestError(404, "screenshot_not_found");
    return this.readFile(identity, image.fileId, method, request);
  }

  private async readableFile(identity: Identity, fileId: string, variant?: ScreenshotVariant) {
    const file = await this.store.withIdentity(identity, (scoped) => scoped.getFile(fileId, true));
    if (!file) throw new RequestError(404, "file_not_found");
    if (variant !== undefined && (!Object.hasOwn(SCREENSHOT_VARIANTS, variant)
      || !this.screenshotTransformer || !imageContentTypes.has(file.contentType))) {
      throw new RequestError(404, "file_variant_unavailable");
    }
    return file;
  }

  // Shared by HTTP delivery and server-side consumers; authorization is checked on every read.
  async readFileContent(identity: Identity, fileId: string, variant?: ScreenshotVariant,
    method: StorageReadMethod = "GET", request: Request = new Request("https://dahlia.invalid/")) {
    const file = await this.readableFile(identity, fileId, variant);
    return this.readFileBytes(identity, file, variant, method, request);
  }

  private async readFileBytes(identity: Identity, file: FileRecord, variant: ScreenshotVariant | undefined,
    method: StorageReadMethod, request: Request) {
    const fileId = file.fileId;
    if (variant !== undefined) await this.ensureFileVariant(identity, file, variant);
    const current = await this.store.withIdentity(identity, (scoped) => scoped.getFile(fileId, true));
    if (!current || current.checksum !== file.checksum) throw new RequestError(404, "file_not_found");
    const upstream = await this.storageCall(() => this.requireStorage().read(
      variant ? fileVariantKey(fileId, variant) : fileStorageKey(fileId), method, request,
    ));
    return { file, upstream, contentType: variant ? "image/webp" : file.contentType };
  }

  async readFile(identity: Identity, fileId: string, method: StorageReadMethod, request: Request, variant?: ScreenshotVariant): Promise<Response> {
    const file = await this.readableFile(identity, fileId, variant);
    const checksum = file.checksum.slice(8);
    const etag = variant ? `${checksum}-v1-${variant}` : checksum;
    const headers = new Headers({ "content-security-policy": "sandbox", "x-content-type-options": "nosniff",
      "content-type": variant ? "image/webp" : file.contentType, "cache-control": "private, no-cache",
      "x-dahlia-original-sha256": checksum, "x-dahlia-image-variant": variant ?? "original",
      vary: "Authorization, Cookie",
      etag: `"${etag}"`,
    });
    return conditionalRead(request, method, headers, async (readMethod, readRequest) => {
      const { upstream } = await this.readFileBytes(identity, file, variant, readMethod, readRequest);
      return upstream;
    });
  }

  private ensureFileVariant(identity: Identity, file: FileRecord, variant: ScreenshotVariant): Promise<void> {
    const key = fileVariantKey(file.fileId, variant);
    const existing = this.variantJobs.get(key);
    if (existing) return existing;
    if (this.variantJobs.size >= 32) throw new RequestError(503, "file_transform_busy");
    const job = this.generateFileVariant(identity, file, variant).finally(() => this.variantJobs.delete(key));
    this.variantJobs.set(key, job);
    return job;
  }

  private async generateFileVariant(identity: Identity, file: FileRecord, variant: ScreenshotVariant): Promise<void> {
    if (this.activeVariants >= 2) await new Promise<void>((resolve) => this.variantWaiters.push(resolve));
    else this.activeVariants += 1;
    const originalKey = fileStorageKey(file.fileId);
    const key = fileVariantKey(file.fileId, variant);
    try {
      await this.withStorageOperation(originalKey, () => this.store.withStorageKeyLock(originalKey, async () => {
        const storage = this.requireStorage();
        const request = new Request("https://dahlia.invalid/", { signal: AbortSignal.timeout(20_000) });
        const isCurrent = async () => !await this.store.hasStorageDelete(originalKey)
          && (await this.store.withIdentity(identity, (scoped) => scoped.getFile(file.fileId, true)))?.checksum === file.checksum;
        if (!await isCurrent()) throw new RequestError(404, "file_not_found");
        if (await this.store.hasStorageDelete(key)) throw new RequestError(503, "file_cache_delete_pending");
        if (await this.storageCall(() => storage.exists(key, request.signal))) return;
        const original = await this.storageCall(() => storage.read(originalKey, "GET", request));
        if (!original.ok || !original.body) throw new RequestError(502, "file_original_unavailable");
        const bytes = await this.screenshotTransformer!(original.body, SCREENSHOT_VARIANTS[variant]);
        if (!await isCurrent()) throw new RequestError(404, "file_not_found");
        try {
          await this.storageCall(() => storage.put(key, bytes, bytes.byteLength, "image/webp", request.signal));
          if (!await isCurrent()) throw new RequestError(404, "file_not_found");
        } catch (error) {
          try { await storage.delete(key); } catch {
            await this.store.enqueueStorageDelete(key);
            this.scheduleStorageDeletes();
          }
          throw error;
        }
      }));
    } finally {
      const next = this.variantWaiters.shift();
      if (next) next();
      else this.activeVariants -= 1;
    }
  }

  listOrganizations(identity: Identity) {
    return this.store.withIdentity(identity, (scoped) => scoped.listOrganizations());
  }

  listVaults(identity: Identity, owner?: string, organizationId?: string) {
    const valid = (value: string) => value.length > 0 && value.length <= 200
      && value === value.trim() && !/[\s]/u.test(value) && ![...value].some((character) => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127);
    if ((owner !== undefined && organizationId !== undefined)
      || (owner !== undefined && !valid(owner))
      || (organizationId !== undefined && !valid(organizationId))) {
      throw new RequestError(400, "invalid_vault_scope");
    }
    return this.store.withIdentity(identity, (scoped) => scoped.listVaults(organizationId, owner));
  }

  getVault(identity: Identity, vaultId: string) {
    return this.store.withIdentity(identity, (scoped) => scoped.getVault(vaultId));
  }

  listProjects(identity: Identity, vaultId: string) {
    return this.store.withIdentity(identity, (scoped) => scoped.listProjects(vaultId));
  }

  async getProjectById(identity: Identity, projectId: string) {
    const vaultId = await this.store.withIdentity(identity, (scoped) => scoped.resolveEntityVault("project", projectId));
    return vaultId ? this.getProject(identity, vaultId, projectId) : null;
  }

  async meetingVault(identity: Identity, meetingId: string): Promise<string> {
    const vaultId = await this.store.withIdentity(identity, (scoped) => scoped.resolveEntityVault("meeting", meetingId));
    if (!vaultId) throw new RequestError(404, "meeting_not_found");
    return vaultId;
  }

  async getMeetingById(identity: Identity, meetingId: string) {
    const vaultId = await this.store.withIdentity(identity, (scoped) => scoped.resolveEntityVault("meeting", meetingId));
    return vaultId ? this.getMeeting(identity, vaultId, meetingId) : null;
  }

  getProject(identity: Identity, vaultId: string, projectId: string) {
    return this.store.withIdentity(identity, (scoped) => scoped.getProject(vaultId, projectId));
  }

  async listMeetings(
    identity: Identity,
    vaultId: string,
    query?: string,
    signal?: AbortSignal,
    projectId?: string,
    cursor?: string,
    projectScope?: string,
  ) {
    if (projectScope !== undefined && (
      !["direct", "unassigned"].includes(projectScope)
      || (projectScope === "direct" && !projectId)
      || (projectScope === "unassigned" && projectId !== undefined)
    )) throw new RequestError(400, "invalid_project_scope");
    const scope = projectScope as "direct" | "unassigned" | undefined;
    const search = this.parseSearchQuery(query);
    if (search?.tokens.length && this.embedder
      && !await this.store.withIdentity(identity, (scoped) => scoped.getVault(vaultId))) return { items: [] };
    if (search) {
      return {
        items: await this.search(identity, search, (scoped, prepared) =>
          scoped.listMeetings(vaultId, prepared, 100, projectId, undefined, scope),
        (meeting) => meeting.meetingId, signal),
      };
    }
    const parsedCursor = this.parseMeetingCursor(cursor);
    const records = await this.store.withIdentity(identity, (scoped) => scoped.listMeetings(
      vaultId,
      undefined,
      SYNC_READ_PAGE_SIZE + 1,
      projectId,
      parsedCursor,
      scope,
    ));
    const items = records.slice(0, SYNC_READ_PAGE_SIZE);
    const last = items.at(-1);
    return {
      items,
      ...(records.length > SYNC_READ_PAGE_SIZE && last
        ? { nextCursor: `${last.createdAt.toISOString()},${last.meetingId}` }
        : {}),
    };
  }

  private parseMeetingCursor(cursor?: string) {
    if (cursor === undefined) return undefined;
    const parsed = meetingCursorSchema.safeParse(cursor.split(","));
    if (!parsed.success) throw new RequestError(400, "invalid_sync_cursor");
    return { createdAt: parsed.data[0], meetingId: parsed.data[1] };
  }

  getMeeting(identity: Identity, vaultId: string, meetingId: string) {
    return this.store.withIdentity(identity, (scoped) => scoped.getMeeting(vaultId, meetingId));
  }

  async listTranscript(identity: Identity, vaultId: string, meetingId: string, cursor?: string,
    options?: { after?: string; wait?: boolean; signal?: AbortSignal; authorize?: () => void | Promise<void> }) {
    if (cursor !== undefined && options?.after !== undefined) throw new RequestError(400, "after_and_cursor_are_exclusive");
    const parsedCursor = this.parseTranscriptCursor(cursor);
    const deadline = Date.now() + (options?.wait ? 25_000 : 0);
    while (true) {
      options?.signal?.throwIfAborted();
      await options?.authorize?.();
      const result = await this.store.withIdentity(identity, async (scoped) => {
        await scoped.lockVault(vaultId);
        if (!await scoped.getMeeting(vaultId, meetingId)) throw new RequestError(404, "meeting_not_found");
        const transcript = await scoped.getTranscript(vaultId, meetingId);
        // HTTP pagination keeps its bounded query; MCP also verifies the previously delivered prefix.
        const records = await scoped.listTranscript(vaultId, meetingId,
          options ? undefined : TRANSCRIPT_READ_PAGE_SIZE + 1, options ? undefined : parsedCursor, transcript?.version);
        let page;
        if (options) {
          let start = 0;
          if (parsedCursor) {
            start = records.findIndex((row) => row.startedAt > parsedCursor.startedAt
              || (row.startedAt.getTime() === parsedCursor.startedAt.getTime() && row.segmentId > parsedCursor.segmentId));
            if (start < 0) start = records.length;
          }
          page = await transcriptCheckpoint(vaultId, meetingId, transcript?.id ?? "none", records,
            options.after, start, TRANSCRIPT_READ_PAGE_SIZE);
        } else {
          page = { items: records.slice(0, TRANSCRIPT_READ_PAGE_SIZE), hasMore: records.length > TRANSCRIPT_READ_PAGE_SIZE };
        }
        const last = page.items.at(-1);
        return { transcript, items: page.items, ...("next_after" in page ? { next_after: page.next_after } : {}),
          ...(page.hasMore && last ? { nextCursor: `${last.startedAt.toISOString()},${last.segmentId}` } : {}) };
      });
      options?.signal?.throwIfAborted();
      if (result.items.length || Date.now() >= deadline) return result;
      await waitForTranscript(options?.signal);
    }
  }

  private parseTranscriptCursor(cursor?: string) {
    if (cursor === undefined) return undefined;
    const parsed = transcriptCursorSchema.safeParse(cursor.split(","));
    if (!parsed.success) throw new RequestError(400, "invalid_sync_cursor");
    return { startedAt: parsed.data[0], segmentId: parsed.data[1] };
  }

  async listScreenshots(
    identity: Identity,
    vaultId: string,
    meetingId: string,
    query?: string,
    signal?: AbortSignal,
    cursor?: string,
  ) {
    const search = this.parseSearchQuery(query);
    if (search?.tokens.length && this.embedder
      && !await this.store.withIdentity(identity, (scoped) => scoped.getMeeting(vaultId, meetingId))) return { items: [] };
    if (search) {
      return {
        items: await this.search(identity, search, (scoped, prepared) =>
          scoped.listScreenshots(vaultId, meetingId, prepared, 100),
        (screenshot) => screenshot.screenshotId, signal),
      };
    }
    const parsedCursor = this.parseScreenshotCursor(cursor);
    const records = await this.store.withIdentity(identity, (scoped) => scoped.listScreenshots(
      vaultId,
      meetingId,
      undefined,
      SYNC_READ_PAGE_SIZE + 1,
      parsedCursor,
    ));
    const items = records.slice(0, SYNC_READ_PAGE_SIZE);
    const last = items.at(-1);
    return {
      items,
      ...(records.length > SYNC_READ_PAGE_SIZE && last
        ? { nextCursor: `${last.capturedAt.toISOString()},${last.screenshotId}` }
        : {}),
    };
  }

  private parseScreenshotCursor(cursor?: string) {
    if (cursor === undefined) return undefined;
    const parsed = screenshotCursorSchema.safeParse(cursor.split(","));
    if (!parsed.success) throw new RequestError(400, "invalid_sync_cursor");
    return { capturedAt: parsed.data[0], screenshotId: parsed.data[1] };
  }

  async listPermissions(identity: Identity, vaultId: string) {
    const permissions = await this.store.withIdentity(identity, (scoped) => scoped.listPermissions(vaultId));
    if (!permissions) throw new RequestError(404, "vault_not_found");
    return permissions;
  }

  async putMemberPermission(
    identity: Identity,
    vaultId: string,
    principalType: VaultPrincipalType,
    principalId: string,
  ): Promise<void> {
    this.requireWritableIdentity(identity);
    if (!await this.store.withIdentity(
      identity,
      (scoped) => scoped.putMemberPermission(vaultId, principalType, principalId),
    )) {
      throw new RequestError(404, "vault_or_permission_target_not_found");
    }
  }

  async deleteMemberPermission(
    identity: Identity,
    vaultId: string,
    principalType: VaultPrincipalType,
    principalId: string,
  ): Promise<void> {
    this.requireWritableIdentity(identity);
    if (!await this.store.withIdentity(
      identity,
      (scoped) => scoped.deleteMemberPermission(vaultId, principalType, principalId),
    )) {
      throw new RequestError(404, "vault_permission_not_found");
    }
  }

  private requireWritableIdentity(identity: Identity): void {
    if (identity.impersonated) throw new RequestError(403, "impersonated_session_read_only");
  }

  private requireStorage(): ObjectStorage {
    if (!this.storage) throw new RequestError(503, "object_storage_not_configured");
    return this.storage;
  }

  private parseSearchQuery(query: string | undefined) {
    try {
      return parseSearchQuery(this.tokenizer, query);
    } catch (error) {
      if (error instanceof SearchQueryError) throw new RequestError(400, error.message);
      throw error;
    }
  }

  private async search<T>(
    identity: Identity,
    query: SearchQuery | undefined,
    operation: (store: IdentitySyncStore, query: SyncSearchQuery | undefined) => Promise<T[]>,
    documentId: (record: T) => string,
    signal?: AbortSignal,
  ): Promise<T[]> {
    if (!query?.tokens.length || !this.embedder) {
      return this.store.withIdentity(identity, (scoped) => operation(scoped, query));
    }
    const fallback = this.store.withIdentity(identity, (scoped) => operation(scoped, query));
    if (signal?.aborted || this.activeQueryEmbeddingUsers.has(identity.userId)
      || this.activeQueryEmbeddingUsers.size >= QUERY_EMBEDDING_CONCURRENCY) return fallback;
    this.activeQueryEmbeddingUsers.add(identity.userId);
    const deadline = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const embeddingSignal = signal ? AbortSignal.any([signal, deadline.signal]) : deadline.signal;
    const embedding = this.embedder.embedQuery(query.sourceText, embeddingSignal).catch((error) => {
      if (!embeddingSignal.aborted) {
        console.warn(JSON.stringify({
          level: "warn",
          event: "search_query_embedding_failed",
          errorName: error instanceof Error ? error.name : "UnknownError",
        }));
      }
      return undefined;
    });
    let vector: number[] | undefined;
    try {
      vector = await Promise.race([
        embedding,
        new Promise<undefined>((resolve) => {
          timer = setTimeout(() => {
            deadline.abort();
            resolve(undefined);
          }, QUERY_EMBEDDING_DEADLINE_MS);
        }),
      ]);
    } finally {
      if (timer) clearTimeout(timer);
      this.activeQueryEmbeddingUsers.delete(identity.userId);
    }
    const fallbackResult = await fallback;
    if (!vector) return fallbackResult;
    try {
      return await this.store.withIdentity(identity, (scoped) => operation(scoped, {
        ...query,
        ftsCandidateIds: fallbackResult.map(documentId),
        embedding: { model: this.embedder!.model, dimensions: this.embedder!.dimensions, vector },
      }));
    } catch (error) {
      console.warn(JSON.stringify({
        level: "warn",
        event: "search_hybrid_query_failed",
        errorName: error instanceof Error ? error.name : "UnknownError",
      }));
      return fallbackResult;
    }
  }

  private async storageCall<T>(operation: () => Promise<T>): Promise<T> {
    try {
      return await operation();
    } catch (error) {
      if (error instanceof RequestError) throw error;
      const code = error instanceof ObjectStorageError ? error.code : "object_storage_unavailable";
      throw new RequestError(502, code);
    }
  }
}

async function embeddingContentHash(text: string | null): Promise<string | null> {
  if (!text) return null;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value instanceof Date) return JSON.stringify(value.toISOString());
  if (value && typeof value === "object") {
    return `{${Object.entries(value).sort(([left], [right]) => left.localeCompare(right))
      .map(([key, child]) => `${JSON.stringify(key)}:${canonicalJson(child)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

async function normalizeTransaction(body: unknown): Promise<SyncTransaction> {
  const parsed = transactionSchema.safeParse(body);
  if (!parsed.success
    || new Set(parsed.data.operations.map(({ id }) => id)).size !== parsed.data.operations.length
    || new Set(parsed.data.operations.map(({ entity, entityId }) => `${entity}:${entityId}`)).size !== parsed.data.operations.length) {
    throw new RequestError(400, "invalid_sync_transaction");
  }
  const operations: SyncTransaction["operations"] = [];
  for (const operation of parsed.data.operations) {
    const key = `${operation.entity}:${operation.action}` as keyof typeof transactionDataSchemas;
    const schema = transactionDataSchemas[key];
    const data = schema?.safeParse(operation.data ?? {});
    if (!data?.success || (operation.entity === "vault" && operation.entityId !== parsed.data.vaultId)) {
      throw new SyncTransactionError(400, "invalid_sync_operation", [], operation.id);
    }
    operations.push({ ...operation, data: data.data });
  }
  const normalized = { ...parsed.data, operations };
  const requestHash = await sha256(canonicalJson(normalized));
  return { ...normalized, requestHash };
}

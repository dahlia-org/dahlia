import { z } from "zod";
import { uuidV7 } from "../id";
import { imageAnalysisSchema, type ImageAnalysisInput, type ImageAnalysis } from "../image-analysis/model";

import type { Identity } from "../auth/identity";
import { DEFAULT_ARTIFACT_MAX_BYTES } from "../config";
import { ObjectStorageError, type ArtifactReadMethod, type ObjectStorage } from "../artifacts/storage";
import { ArtifactRequestError, parseUpload } from "../artifacts/upload";
import { sha256Passthrough, sha256Stream } from "../artifacts/sha256";
import {
  createSearchText,
  createIntlSearchTokenizer,
  parseSearchQuery,
  SearchQueryError,
  type SearchQuery,
  type SearchTokenizer,
} from "../search/tokenizer";
import { summarySearchableText } from "../search/summary";
import type { SearchEmbedder } from "../search/embedding";
import type {
  IdentitySyncStore,
  MeetingSyncStore,
  SyncSearchQuery,
  SyncTransaction,
  VaultPrincipalType,
} from "./types";
import { decodeSyncCursor, encodeSyncCursor, SYNC_SNAPSHOT_ENTITIES, SyncTransactionError } from "./store";
import { fileMetadataSchema, fileUploadQuerySchema, filePatchSchema, fileResponse, fileStorageKey, fileVariantKey, imageContentTypes, type FileRecord } from "../files/model";
import { SCREENSHOT_VARIANTS, screenshotVariantKey, type ScreenshotTransformer, type ScreenshotVariant } from "./screenshot-variants";
import { fileTextMetadata, metadataRecord, parseContentMode, parseTextEntity, readTextContent, TEXT_CONTENT_VERSION } from "./text-content";

const uuidSchema = z.uuid().transform((value) => value.toLowerCase());
const dateSchema = z.iso.datetime().transform((value) => new Date(value));
const nullableDateSchema = dateSchema.nullable();
const projectNameSchema = z.string().trim().min(1).refine((value) =>
  ![".", ".."].includes(value)
  && ![".", "_"].includes(value[0] ?? "")
  && ![...value].some((character) => "/:".includes(character) || character.charCodeAt(0) <= 31 || character.charCodeAt(0) === 127)
  && new TextEncoder().encode(value).byteLength <= 255,
);
const projectTypeSchema = z.enum(["customer", "internal", "personal", "undefined"]);
const meetingStatusSchema = z.enum([
  "TRANSCRIPT_NOT_FOUND",
  "PROCESSING_TRANSCRIPT",
  "READY",
  "RECORDING",
]).transform((status) => status === "RECORDING" ? "READY" : status);
const transcriptSegmentSchema = z.object({
  segmentId: uuidSchema,
  startTime: dateSchema,
  endTime: nullableDateSchema,
  text: z.string(),
  isConfirmed: z.literal(true),
  audioSource: z.enum(["mic", "system"]).nullable(),
  speakerLabel: z.string().nullable(),
}).strict();
const transcriptChunkSchema = z.object({
  segments: z.array(transcriptSegmentSchema).max(500),
  deletions: z.array(uuidSchema).max(500),
}).strict();

const SCREENSHOT_DELETE_BATCH_SIZE = 25;
const STORAGE_OPERATION_CONCURRENCY = 4;
const QUERY_EMBEDDING_DEADLINE_MS = 2_000;
const QUERY_EMBEDDING_CONCURRENCY = 8;
const permissionPrincipalSchema = z.string().trim().min(1).max(200);
export const SYNC_READ_PAGE_SIZE = 200;
const TRANSCRIPT_READ_PAGE_SIZE = 10_000;
const TRANSCRIPT_PATCH_ITEM_LIMIT = 50_000;
const TRANSCRIPT_PATCH_CHUNK_LIMIT = 100;
const SUMMARY_DOCUMENT_MAX_SERIALIZED_BYTES = 6 * 1024 * 1024;
const summaryDocumentSchema = z.string().refine(
  (value) => new TextEncoder().encode(JSON.stringify(value)).byteLength <= SUMMARY_DOCUMENT_MAX_SERIALIZED_BYTES,
  "Summary document is too large",
);
const meetingCursorSchema = z.tuple([dateSchema, uuidSchema]);
const screenshotCursorSchema = z.tuple([dateSchema, uuidSchema]);
const transcriptCursorSchema = z.tuple([dateSchema, uuidSchema]);
const uuidV7Schema = z.string()
  .regex(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i)
  .transform((value) => value.toLowerCase());
const transactionOperationSchema = z.object({
  id: uuidV7Schema,
  entity: z.enum(["vault", "project", "meeting", "summary", "transcript", "file", "meeting_file", "meeting_event"]),
  action: z.enum(["create", "update", "delete", "upsert", "patch", "reset"]),
  entityId: uuidSchema,
  baseRevision: z.number().int().nonnegative().nullable(),
  data: z.record(z.string(), z.unknown()).nullable(),
}).strict();
const transactionSchema = z.object({
  schemaVersion: z.literal(2),
  id: uuidV7Schema,
  vaultId: uuidSchema,
  createdAt: dateSchema,
  operations: z.array(transactionOperationSchema).min(1).max(10_000),
}).strict();
const transactionDataSchemas = {
  "meeting_event:create": z.discriminatedUnion("kind", [
    z.object({ meetingId: uuidSchema, kind: z.enum(["tag_added", "tag_removed"]), occurredAt: dateSchema, relatedId: z.string().regex(/^[0-9]{1,19}$/) }).strict(),
    z.object({ meetingId: uuidSchema, kind: z.enum(["recording_started", "recording_ended"]), occurredAt: dateSchema, sessionId: uuidSchema }).strict(),
    z.object({ meetingId: uuidSchema, kind: z.literal("segment_rotated"), occurredAt: dateSchema, sessionId: uuidSchema, relatedId: uuidSchema, audioSource: z.enum(["mic", "system"]), segmentIndex: z.number().int().positive().max(2147483647) }).strict(),
  ]),
  "vault:create": z.object({ name: z.string().trim().min(1), createdAt: dateSchema }).strict(),
  "vault:update": z.object({ name: z.string().trim().min(1) }).strict(),
  "vault:reset": z.object({ preservePermissions: z.boolean().optional() }).strict(),
  "project:create": z.object({ parentProjectId: uuidSchema.nullable(), name: projectNameSchema, description: z.string().max(20_000).default(""), projectType: projectTypeSchema.nullable(), createdAt: dateSchema }).strict(),
  "project:update": z.object({ parentProjectId: uuidSchema.nullable(), name: projectNameSchema, description: z.string().max(20_000).default(""), projectType: projectTypeSchema.nullable() }).strict(),
  "project:delete": z.object({}).strict(),
  "meeting:create": z.object({ projectId: uuidSchema.nullable(), name: z.string(), description: z.string().default(""), status: meetingStatusSchema, duration: z.number().finite().nonnegative().nullable(), recordingStartedAt: nullableDateSchema, createdAt: dateSchema, updatedAt: dateSchema }).strict(),
  "meeting:update": z.object({ projectId: uuidSchema.nullable(), name: z.string(), description: z.string().default(""), status: meetingStatusSchema, duration: z.number().finite().nonnegative().nullable(), recordingStartedAt: nullableDateSchema, updatedAt: dateSchema }).strict(),
  "meeting:delete": z.object({}).strict(),
  "summary:upsert": z.object({ title: z.string(), document: summaryDocumentSchema, createdAt: dateSchema }).strict(),
  "summary:delete": z.object({}).strict(),
  "transcript:patch": z.object({
    patchId: uuidV7Schema,
    segmentCount: z.number().int().nonnegative().max(TRANSCRIPT_PATCH_ITEM_LIMIT),
    deletionCount: z.number().int().nonnegative().max(TRANSCRIPT_PATCH_ITEM_LIMIT),
    chunks: z.array(z.object({
      index: z.number().int().nonnegative(),
      sha256: z.string().regex(/^[0-9a-f]{64}$/),
      segmentCount: z.number().int().nonnegative().max(500),
      deletionCount: z.number().int().nonnegative().max(500),
    }).strict()).min(1).max(TRANSCRIPT_PATCH_CHUNK_LIMIT),
  }).strict().superRefine((patch, context) => {
    if (patch.chunks.reduce((sum, chunk) => sum + chunk.segmentCount, 0) !== patch.segmentCount
      || patch.chunks.reduce((sum, chunk) => sum + chunk.deletionCount, 0) !== patch.deletionCount
      || patch.chunks.some((chunk, index) => chunk.index !== index)) {
      context.addIssue({ code: "custom", message: "Invalid transcript patch manifest" });
    }
  }),
  "file:upsert": z.object({ name: z.string().min(1).max(255).optional(), checksum: z.string().regex(/^SHA-256:[0-9a-f]{64}$/), metadata: fileMetadataSchema.partial() }).strict(),
  "file:delete": z.object({}).strict(),
  "meeting_file:upsert": z.object({ meetingId: uuidSchema, fileId: uuidSchema, capturedAt: nullableDateSchema, sessionId: uuidSchema.nullable(), createdAt: dateSchema }).strict(),
  "meeting_file:delete": z.object({}).strict(),
} as const;
const SYNC_CHANGE_PAGE_SIZE = 100;

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
  ) {
    if (storage) {
      this.scheduleStorageDeletes();
    }
  }

  parseId(value: string): string {
    if (value !== value.toLowerCase()) throw new ArtifactRequestError(400, "invalid_sync_id");
    const parsed = uuidSchema.safeParse(value);
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_sync_id");
    return parsed.data;
  }

  parsePermissionPrincipal(value: string): string {
    const parsed = permissionPrincipalSchema.safeParse(value);
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_sync_share_target");
    return parsed.data;
  }

  async resolveTransaction(identity: Identity, body: unknown) {
    this.requireWritableIdentity(identity);
    const transaction = await normalizeTransaction(body);
    return this.store.withIdentity(identity, async (scoped) =>
      await scoped.resolveTransaction(transaction) ?? { id: transaction.id, status: "unknown" as const },
    );
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
        baseRevision: input.file.revision, data: { checksum: input.file.checksum, metadata },
      }],
    });
    Object.assign(transaction.operations[0]!.data!, await this.fileSearchData(metadata));
    return this.store.withIdentity(identity, (scoped) => scoped.completeImageAnalysis(input, transaction));
  }

  private async fileSearchData(metadata: Partial<FileRecord["metadata"]>) {
    const embeddingText = [metadata.ocr_text, metadata.caption]
      .filter((value): value is string => typeof value === "string" && value.trim().length > 0).join("\n") || null;
    return {
      searchText: createSearchText(this.tokenizer, [metadata.ocr_text, metadata.caption]),
      embeddingText,
      embeddingContentHash: await embeddingContentHash(embeddingText),
    };
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
            const summaryText = summarySearchableText(summaryDocument);
            const embeddingText = summaryText.trim() || null;
            Object.assign(data, {
              searchText: createSearchText(this.tokenizer, [name, description, summaryText]),
              embeddingText,
              embeddingContentHash: await embeddingContentHash(embeddingText),
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
          } else if (["file", "meeting_file"].includes(operation.entity) && operation.action === "upsert") {
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

  private scheduleStorageDeletes(): void {
    this.storageDeleteDrain ??= this.drainStorageDeletes()
      .catch(() => undefined)
      .finally(() => {
        this.storageDeleteDrain = undefined;
        this.scheduleStorageDeleteRetry();
      });
  }

  private scheduleStorageDeleteRetry(): void {
    if (this.storageDeleteRetry) return;
    this.storageDeleteRetry = setTimeout(() => {
      this.storageDeleteRetry = undefined;
      this.scheduleStorageDeletes();
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
            error instanceof ObjectStorageError ? error.code : "artifact_storage_unavailable",
          );
          this.scheduleStorageDeleteRetry();
        }
      }
    }
  }

  async listChanges(identity: Identity, vaultId: string, cursor?: string, highWaterCursor?: string, content?: string) {
    const contentMode = parseContentMode(content);
    const after = cursor ? decodeSyncCursor(cursor) : 0;
    const suppliedHighWater = highWaterCursor ? decodeSyncCursor(highWaterCursor) : undefined;
    if (suppliedHighWater !== undefined && suppliedHighWater < after) {
      throw new SyncTransactionError(400, "invalid_sync_cursor");
    }
    const { rows, highWater } = await this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      const highWater = suppliedHighWater ?? await scoped.latestChangeSequence(vaultId);
      const rows = await scoped.listChanges(vaultId, after, highWater, SYNC_CHANGE_PAGE_SIZE + 1);
      if (contentMode) {
        for (const row of rows) {
          row.record = (await metadataRecord({ entity: row.entity, id: row.entityId, revision: row.revision, record: row.record }, scoped, vaultId)).record;
        }
      }
      return { rows, highWater };
    });
    const items = rows.slice(0, SYNC_CHANGE_PAGE_SIZE);
    const last = items.at(-1);
    return {
      items,
      cursor: encodeSyncCursor(rows.length > SYNC_CHANGE_PAGE_SIZE ? last!.sequence : highWater),
      highWaterCursor: encodeSyncCursor(highWater),
      hasMore: rows.length > SYNC_CHANGE_PAGE_SIZE,
      ...(contentMode ? { contentMode } : {}),
    };
  }

  async listSnapshot(identity: Identity, vaultId: string, cursor?: string, startCursor?: string, content?: string) {
    const contentMode = parseContentMode(content);
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
        items: contentMode ? await Promise.all(items.map((item) => metadataRecord(item, scoped, vaultId))) : items,
        startCursor: encodeSyncCursor(start),
        nextCursor: hasMore && last ? `${last.entity},${last.id}` : null,
        ...(contentMode ? { contentMode } : {}),
      };
    });
  }

  async textContent(identity: Identity, vaultId: string, entityValue: string, entityId: string,
    revisionValue?: string, manifestValue?: string, cursor?: string) {
    const entity = parseTextEntity(entityValue);
    if (!revisionValue || !/^\d+$/.test(revisionValue) || !Number.isSafeInteger(Number(revisionValue))
      || (manifestValue !== undefined && manifestValue !== "1") || (cursor && (manifestValue || entity !== "transcript"))) {
      throw new SyncTransactionError(400, "invalid_content_request");
    }
    const after = cursor ? this.parseTranscriptCursor(cursor) : undefined;
    return this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      return readTextContent(scoped, vaultId, entity, entityId, Number(revisionValue), manifestValue === "1", after);
    });
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
    vaultId: string,
    meetingId: string,
    patchId: string,
    chunkIndex: number,
    contentHash: string,
    body: unknown,
  ): Promise<void> {
    const parsed = transcriptChunkSchema.safeParse(body);
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_transcript_chunk");
    const accepted = await this.store.withIdentity(identity, (scoped) => scoped.putTranscriptChunk(
      vaultId,
      meetingId,
      patchId,
      chunkIndex,
      contentHash,
      parsed.data.segments,
      parsed.data.deletions,
    ));
    if (!accepted) throw missingMeetingConflict(meetingId);
  }

  async postFile(identity: Identity, request: Request) {
    this.requireWritableIdentity(identity);
    const storage = this.requireStorage();
    if (!this.fileStorageRoot) throw new ArtifactRequestError(503, "file_storage_not_configured");
    const query = new URL(request.url).searchParams;
    const parsed = fileUploadQuerySchema.safeParse(Object.fromEntries(query));
    if (!parsed.success || [...query.keys()].some((key) => query.getAll(key).length !== 1)) {
      throw new ArtifactRequestError(400, "invalid_file_upload");
    }
    const { id: fileId, vaultId, name, ...metadata } = parsed.data;
    const upload = parseUpload(request, DEFAULT_ARTIFACT_MAX_BYTES);
    if (!/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/.test(upload.contentType)) {
      throw new ArtifactRequestError(400, "invalid_content_type");
    }
    const key = fileStorageKey(fileId);
    return this.withStorageOperation(key, () => this.store.withStorageKeyLock(key, async () => {
      const now = new Date();
      const file = await this.store.withIdentity(identity, async (scoped) => {
        await scoped.expireFileUploads(vaultId, new Date(now.getTime() - 86_400_000));
        return scoped.reserveFile({ fileId, vaultId,
          uri: `${this.fileStorageRoot}/${key}`, offset: 0, size: 0, checksum: "",
          contentType: upload.contentType, name, metadata,
          active: false, uploadedAt: null, revision: 0, createdAt: now, updatedAt: now,
        });
      });
      this.scheduleStorageDeletes();
      if (!file) throw new ArtifactRequestError(404, "file_or_vault_not_found");
      if (file.contentType !== upload.contentType || file.metadata.source !== metadata.source
        || (file.uploadedAt && file.size !== upload.contentLength)) {
        throw new ArtifactRequestError(409, "file_id_conflict");
      }
      if (await this.store.hasStorageDelete(key)) throw new ArtifactRequestError(503, "file_storage_delete_pending");
      let received = 0;
      const bounded = request.body?.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
        transform(chunk, controller) {
          received += chunk.byteLength;
          if (received > upload.contentLength) throw new ArtifactRequestError(413, "file_size_mismatch");
          controller.enqueue(chunk);
        },
        flush() {
          if (received !== upload.contentLength) throw new ArtifactRequestError(400, "file_size_mismatch");
        },
      })) ?? null;
      if (!bounded && upload.contentLength !== 0) throw new ArtifactRequestError(400, "file_size_mismatch");
      if (file.uploadedAt) {
        if (`SHA-256:${await sha256Stream(bounded)}` !== file.checksum) {
          throw new ArtifactRequestError(409, "file_checksum_mismatch");
        }
        return { file: this.fileMetadata(fileResponse(file)), created: false };
      }
      try {
        const hashing = sha256Passthrough(bounded);
        const storing = this.storageCall(() => storage.put(key, hashing.body, upload.contentLength, file.contentType, request.signal))
          .catch(async (error: unknown) => {
            await hashing.cancel(error).catch(() => undefined);
            throw error;
          });
        const [stored, digest] = await Promise.allSettled([storing, hashing.digest]);
        if (digest.status === "rejected") throw digest.reason;
        if (stored.status === "rejected") throw stored.reason;
        const uploaded = await this.store.withIdentity(identity, (scoped) => scoped.markFileUploaded(file, received, `SHA-256:${digest.value}`));
        if (!uploaded) {
          const current = await this.store.withIdentity(identity, (scoped) => scoped.getFile(fileId));
          if (current?.vaultId === file.vaultId && await this.store.hasStorageDelete(key)) {
            throw new ArtifactRequestError(503, "file_storage_delete_pending");
          }
          throw new ArtifactRequestError(404, "file_not_found");
        }
        return { file: this.fileMetadata(fileResponse(uploaded)), created: true };
      } catch (error) {
        try { await storage.delete(key); } catch {
          await this.store.enqueueStorageDelete(key);
          this.scheduleStorageDeletes();
        }
        throw error;
      }
    }));
  }

  async patchFile(identity: Identity, fileId: string, body: unknown) {
    this.requireWritableIdentity(identity);
    const parsed = filePatchSchema.safeParse(body);
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_file_patch");
    const file = await this.store.withIdentity(identity, (scoped) => scoped.getFile(fileId));
    if (!file?.active) throw new ArtifactRequestError(404, "file_not_found");
    const response = await this.commitTransaction(identity, {
      schemaVersion: 2, id: uuidV7(), vaultId: file.vaultId, createdAt: new Date().toISOString(),
      operations: [{ id: uuidV7(), entity: "file", action: "upsert", entityId: fileId,
        baseRevision: parsed.data.baseRevision, data: { checksum: file.checksum, metadata: parsed.data.metadata } }],
    });
    const record = response.records.find((record) => record.entity === "file" && record.id === fileId)!;
    return this.fileMetadata(record.record as ReturnType<typeof fileResponse>);
  }

  async getFile(identity: Identity, fileId: string, content?: string) {
    const mode = parseContentMode(content);
    const file = await this.store.withIdentity(identity, (scoped) => scoped.getFile(fileId, true));
    if (!file) throw new ArtifactRequestError(404, "file_not_found");
    const record = this.fileMetadata(fileResponse(file));
    return mode ? fileTextMetadata(record) : record;
  }

  private fileMetadata(file: ReturnType<typeof fileResponse>) {
    const variants: Record<string, string> = {};
    if (this.screenshotTransformer && imageContentTypes.has(file.content_type)) {
      for (const variant of Object.keys(SCREENSHOT_VARIANTS)) {
        variants[variant] = `/api/v1/files/${file.id}/variants/${variant}`;
      }
    }
    return { ...file, contentURL: `/api/v1/files/${file.id}`, variants };
  }

  async listFiles(identity: Identity, vaultId: string, cursor?: string, meetingId?: string) {
    const after = cursor === undefined ? undefined : this.parseId(cursor);
    return this.store.withIdentity(identity, async (scoped) => {
      if (meetingId) {
        const rows = await scoped.listMeetingFiles(vaultId, meetingId, after, SYNC_READ_PAGE_SIZE + 1);
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
    method: ArtifactReadMethod, request: Request): Promise<Response> {
    const image = await this.store.withIdentity(identity, (scoped) => scoped.getScreenshot(vaultId, meetingId, screenshotId, true));
    if (!image) throw new ArtifactRequestError(404, "screenshot_not_found");
    return this.readFile(identity, image.fileId, method, request);
  }

  private async readableFile(identity: Identity, fileId: string, variant?: ScreenshotVariant) {
    const file = await this.store.withIdentity(identity, (scoped) => scoped.getFile(fileId, true));
    if (!file) throw new ArtifactRequestError(404, "file_not_found");
    if (variant !== undefined && (!Object.hasOwn(SCREENSHOT_VARIANTS, variant)
      || !this.screenshotTransformer || !imageContentTypes.has(file.contentType))) {
      throw new ArtifactRequestError(404, "file_variant_unavailable");
    }
    return file;
  }

  // Shared by HTTP delivery and server-side consumers; authorization is checked on every read.
  async readFileContent(identity: Identity, fileId: string, variant?: ScreenshotVariant,
    method: ArtifactReadMethod = "GET", request: Request = new Request("https://dahlia.invalid/")) {
    const file = await this.readableFile(identity, fileId, variant);
    return this.readFileBytes(identity, file, variant, method, request);
  }

  private async readFileBytes(identity: Identity, file: FileRecord, variant: ScreenshotVariant | undefined,
    method: ArtifactReadMethod, request: Request) {
    const fileId = file.fileId;
    if (variant !== undefined) await this.ensureFileVariant(identity, file, variant);
    const current = await this.store.withIdentity(identity, (scoped) => scoped.getFile(fileId, true));
    if (!current || current.checksum !== file.checksum) throw new ArtifactRequestError(404, "file_not_found");
    const upstream = await this.storageCall(() => this.requireStorage().read(
      variant ? fileVariantKey(fileId, variant) : fileStorageKey(fileId), method, request,
    ));
    return { file, upstream, contentType: variant ? "image/webp" : file.contentType };
  }

  async readFile(identity: Identity, fileId: string, method: ArtifactReadMethod, request: Request, variant?: ScreenshotVariant): Promise<Response> {
    const file = await this.readableFile(identity, fileId, variant);
    const checksum = file.checksum.slice(8);
    const etag = variant ? `${checksum}-v1-${variant}` : checksum;
    const headers = new Headers({ "content-security-policy": "sandbox", "x-content-type-options": "nosniff",
      "content-type": variant ? "image/webp" : file.contentType, "cache-control": "private, no-cache",
      "x-dahlia-original-sha256": checksum, "x-dahlia-image-variant": variant ?? "original",
      vary: "Authorization, Cookie",
      etag: `"${etag}"`,
    });
    const ifNoneMatch = request.headers.get("if-none-match");
    const notModified = ifNoneMatch?.split(",").some((value) => {
      const tag = value.trim();
      return tag === "*" || tag.replace(/^W\//, "") === headers.get("etag");
    });
    if (notModified && !request.headers.has("if-unmodified-since")) {
      return new Response(null, { status: 304, headers });
    }
    let readRequest = request;
    if (notModified) {
      // Date preconditions precede cache validation; ranges are evaluated only after both.
      readRequest = new Request(request);
      readRequest.headers.delete("range");
    }
    const { upstream } = await this.readFileBytes(identity, file, variant, notModified ? "HEAD" : method, readRequest);
    if (notModified && upstream.ok) return new Response(null, { status: 304, headers });
    if (!upstream.ok) headers.set("cache-control", "no-store");
    for (const name of ["accept-ranges", "content-length", "content-range", "last-modified"]) {
      const value = upstream.headers.get(name);
      if (value) headers.set(name, value);
    }
    return new Response(method === "HEAD" ? null : upstream.body, { status: upstream.status, headers });
  }

  private ensureFileVariant(identity: Identity, file: FileRecord, variant: ScreenshotVariant): Promise<void> {
    const key = fileVariantKey(file.fileId, variant);
    const existing = this.variantJobs.get(key);
    if (existing) return existing;
    if (this.variantJobs.size >= 32) throw new ArtifactRequestError(503, "file_transform_busy");
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
        if (!await isCurrent()) throw new ArtifactRequestError(404, "file_not_found");
        if (await this.store.hasStorageDelete(key)) throw new ArtifactRequestError(503, "file_cache_delete_pending");
        if (await this.storageCall(() => storage.exists(key, request.signal))) return;
        const original = await this.storageCall(() => storage.read(originalKey, "GET", request));
        if (!original.ok || !original.body) throw new ArtifactRequestError(502, "file_original_unavailable");
        const bytes = await this.screenshotTransformer!(original.body, SCREENSHOT_VARIANTS[variant]);
        if (!await isCurrent()) throw new ArtifactRequestError(404, "file_not_found");
        try {
          await this.storageCall(() => storage.put(key, bytes, bytes.byteLength, "image/webp", request.signal));
          if (!await isCurrent()) throw new ArtifactRequestError(404, "file_not_found");
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

  listVaults(identity: Identity, userId?: string, organizationId?: string) {
    const valid = (value: string) => value.length > 0 && value.length <= 200
      && value === value.trim() && !/[\s]/u.test(value) && ![...value].some((character) => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127);
    if ((userId !== undefined && organizationId !== undefined)
      || (userId !== undefined && !valid(userId))
      || (organizationId !== undefined && !valid(organizationId))) {
      throw new ArtifactRequestError(400, "invalid_vault_scope");
    }
    if (userId !== undefined && userId !== identity.userId) {
      throw new ArtifactRequestError(403, "user_forbidden");
    }
    return this.store.withIdentity(identity, (scoped) => scoped.listVaults(organizationId));
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

  async getMeetingById(identity: Identity, meetingId: string, content?: string) {
    const vaultId = await this.store.withIdentity(identity, (scoped) => scoped.resolveEntityVault("meeting", meetingId));
    return vaultId ? this.getMeeting(identity, vaultId, meetingId, content) : null;
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
    )) throw new ArtifactRequestError(400, "invalid_project_scope");
    const scope = projectScope as "direct" | "unassigned" | undefined;
    const search = this.parseSearchQuery(query);
    if (search?.tokens.length && this.embedder
      && !await this.store.withIdentity(identity, (scoped) => scoped.getVault(vaultId))) return { items: [] };
    if (search) {
      return {
        items: await this.search(identity, search, (scoped, prepared) =>
          scoped.listMeetings(vaultId, prepared, SYNC_READ_PAGE_SIZE, projectId, undefined, scope),
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
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_sync_cursor");
    return { createdAt: parsed.data[0], meetingId: parsed.data[1] };
  }

  getMeeting(identity: Identity, vaultId: string, meetingId: string, content?: string) {
    const mode = parseContentMode(content);
    return this.store.withIdentity(identity, async (scoped) => {
      const meeting = await scoped.getMeeting(vaultId, meetingId);
      return meeting && mode ? (await metadataRecord({ entity: "meeting", id: meetingId, revision: meeting.revision ?? 0, record: { ...meeting } }, scoped, vaultId)).record : meeting;
    });
  }

  async listTranscript(identity: Identity, vaultId: string, meetingId: string, cursor?: string) {
    const parsedCursor = this.parseTranscriptCursor(cursor);
    const records = await this.store.withIdentity(identity, (scoped) => scoped.listTranscript(
      vaultId,
      meetingId,
      TRANSCRIPT_READ_PAGE_SIZE + 1,
      parsedCursor,
    ));
    const items = records.slice(0, TRANSCRIPT_READ_PAGE_SIZE);
    const last = items.at(-1);
    return {
      items,
      ...(records.length > TRANSCRIPT_READ_PAGE_SIZE && last
        ? { nextCursor: `${last.startTime.toISOString()},${last.segmentId}` }
        : {}),
    };
  }

  private parseTranscriptCursor(cursor?: string) {
    if (cursor === undefined) return undefined;
    const parsed = transcriptCursorSchema.safeParse(cursor.split(","));
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_sync_cursor");
    return { startTime: parsed.data[0], segmentId: parsed.data[1] };
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
          scoped.listScreenshots(vaultId, meetingId, prepared, SYNC_READ_PAGE_SIZE),
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
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_sync_cursor");
    return { capturedAt: parsed.data[0], screenshotId: parsed.data[1] };
  }

  async listPermissions(identity: Identity, vaultId: string) {
    const permissions = await this.store.withIdentity(identity, (scoped) => scoped.listPermissions(vaultId));
    if (!permissions) throw new ArtifactRequestError(404, "vault_not_found");
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
      throw new ArtifactRequestError(404, "vault_or_permission_target_not_found");
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
      throw new ArtifactRequestError(404, "vault_permission_not_found");
    }
  }

  private requireWritableIdentity(identity: Identity): void {
    if (identity.impersonated) throw new ArtifactRequestError(403, "impersonated_session_read_only");
  }

  private requireStorage(): ObjectStorage {
    if (!this.storage) throw new ArtifactRequestError(503, "artifact_storage_not_configured");
    return this.storage;
  }

  private parseSearchQuery(query: string | undefined) {
    try {
      return parseSearchQuery(this.tokenizer, query);
    } catch (error) {
      if (error instanceof SearchQueryError) throw new ArtifactRequestError(400, error.message);
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
      if (error instanceof ArtifactRequestError) throw error;
      const code = error instanceof ObjectStorageError ? error.code : "artifact_storage_unavailable";
      throw new ArtifactRequestError(502, code);
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

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function normalizeTransaction(body: unknown): Promise<SyncTransaction> {
  const parsed = transactionSchema.safeParse(body);
  if (!parsed.success
    || new Set(parsed.data.operations.map(({ id }) => id)).size !== parsed.data.operations.length
    || new Set(parsed.data.operations.map(({ entity, entityId }) => `${entity}:${entityId}`)).size !== parsed.data.operations.length) {
    throw new ArtifactRequestError(400, "invalid_sync_transaction");
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

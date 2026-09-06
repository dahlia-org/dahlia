import { z } from "zod";

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
  SyncScreenshotRecord,
  SyncSearchQuery,
  SyncTransaction,
  VaultPrincipalType,
} from "./types";
import { decodeSyncCursor, encodeSyncCursor, SYNC_SNAPSHOT_ENTITIES, SyncTransactionError } from "./store";
import { SCREENSHOT_VARIANTS, screenshotVariantKey, type ScreenshotTransformer, type ScreenshotVariant } from "./screenshot-variants";

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

const SCREENSHOT_CONTENT_TYPES = new Map([
  ["image/png", "png"],
  ["image/jpeg", "jpeg"],
  ["image/webp", "webp"],
  ["image/gif", "gif"],
  ["image/tiff", "tiff"],
]);
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
  entity: z.enum(["vault", "project", "meeting", "summary", "transcript", "screenshot"]),
  action: z.enum(["create", "update", "delete", "upsert", "patch", "reset"]),
  entityId: uuidSchema,
  baseRevision: z.number().int().nonnegative().nullable(),
  data: z.record(z.string(), z.unknown()).nullable(),
}).strict();
const transactionSchema = z.object({
  schemaVersion: z.literal(1),
  id: uuidV7Schema,
  vaultId: uuidSchema,
  createdAt: dateSchema,
  operations: z.array(transactionOperationSchema).min(1).max(10_000),
}).strict();
const transactionDataSchemas = {
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
  "screenshot:upsert": z.object({ meetingId: uuidSchema, capturedAt: dateSchema, ocrText: z.string().nullable(), caption: z.string().nullable(), contentHash: z.string().regex(/^[0-9a-f]{64}$/).nullable() }).strict(),
  "screenshot:delete": z.object({}).strict(),
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
  private readonly variantJobs = new Map<string, Promise<Uint8Array<ArrayBuffer> | undefined>>();
  private readonly variantWaiters: Array<() => void> = [];
  private activeVariants = 0;

  constructor(
    private readonly store: MeetingSyncStore,
    private readonly storage?: ObjectStorage,
    private readonly tokenizer: SearchTokenizer = createIntlSearchTokenizer(),
    private readonly embedder?: SearchEmbedder,
    private readonly screenshotTransformer?: ScreenshotTransformer,
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
          } else if (operation.entity === "screenshot" && operation.action === "upsert") {
            const embeddingText = [data.ocrText, data.caption]
              .filter((value): value is string => typeof value === "string" && value.trim().length > 0).join("\n") || null;
            Object.assign(data, {
              searchText: createSearchText(this.tokenizer, [data.ocrText as string | null, data.caption as string | null]),
              embeddingText,
              embeddingContentHash: await embeddingContentHash(embeddingText),
            });
          }
          prepared.push({ ...operation, data });
        }
        return scoped.commitTransaction({ ...normalized, operations: prepared, requestHash });
      });
    } catch (error) {
      if (error instanceof SyncTransactionError
        && error.status >= 400 && error.status < 500
        && ![408, 425, 429].includes(error.status)) {
        let discardedScreenshot = false;
        try {
          await this.store.withIdentity(identity, async (scoped) => {
            for (const operation of operations) {
              if (operation.entity === "transcript" && operation.action === "patch") {
                await scoped.deleteTranscriptPatch(normalized.vaultId, operation.entityId, operation.id);
              } else if (operation.entity === "screenshot" && operation.action === "upsert") {
                discardedScreenshot = await scoped.discardInactiveScreenshot(
                  normalized.vaultId,
                  operation.entityId,
                ) || discardedScreenshot;
              }
            }
          });
          if (discardedScreenshot) this.scheduleStorageDeletes();
        } catch (cleanupError) {
          if (operations.some(({ entity, action }) => entity === "screenshot" && action === "upsert")) {
            throw cleanupError;
          }
          // A later transcript upload removes expired staging rows if immediate cleanup is unavailable.
        }
      }
      throw error;
    }
    this.scheduleStorageDeletes();
    if (this.screenshotTransformer) {
      for (const operation of operations) {
        if (operation.entity !== "screenshot" || operation.action !== "upsert") continue;
        // Best effort warming. Reads use the same path after interruption or a full queue.
        if (this.variantJobs.size >= 32) break;
        void this.warmThumbnail(identity, normalized.vaultId, String(operation.data?.meetingId), operation.entityId);
      }
    }
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
              for (const variant of Object.keys(SCREENSHOT_VARIANTS) as ScreenshotVariant[]) {
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

  async listChanges(identity: Identity, vaultId: string, cursor?: string, highWaterCursor?: string) {
    const after = cursor ? decodeSyncCursor(cursor) : 0;
    const suppliedHighWater = highWaterCursor ? decodeSyncCursor(highWaterCursor) : undefined;
    if (suppliedHighWater !== undefined && suppliedHighWater < after) {
      throw new SyncTransactionError(400, "invalid_sync_cursor");
    }
    const { rows, highWater } = await this.store.withIdentity(identity, async (scoped) => {
      await scoped.lockVault(vaultId);
      const highWater = suppliedHighWater ?? await scoped.latestChangeSequence(vaultId);
      return {
        rows: await scoped.listChanges(vaultId, after, highWater, SYNC_CHANGE_PAGE_SIZE + 1),
        highWater,
      };
    });
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
        items,
        startCursor: encodeSyncCursor(start),
        nextCursor: hasMore && last ? `${last.entity},${last.id}` : null,
      };
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

  async putScreenshot(
    identity: Identity,
    vaultId: string,
    meetingId: string,
    screenshotId: string,
    request: Request,
  ): Promise<SyncScreenshotRecord> {
    const storage = this.requireStorage();
    const upload = parseUpload(request, DEFAULT_ARTIFACT_MAX_BYTES);
    const extension = SCREENSHOT_CONTENT_TYPES.get(upload.contentType);
    if (!extension) throw new ArtifactRequestError(415, "unsupported_screenshot_type");
    const capturedAt = dateSchema.safeParse(request.headers.get("x-dahlia-captured-at"));
    if (!capturedAt.success) throw new ArtifactRequestError(400, "invalid_screenshot_captured_at");
    const contentHash = request.headers.get("x-dahlia-content-sha256")?.toLowerCase();
    if (!contentHash || !/^[0-9a-f]{64}$/.test(contentHash)) {
      throw new ArtifactRequestError(400, "invalid_screenshot_content_hash");
    }
    const storageKey = `meetings/${meetingId}/screenshots/${screenshotId}.${extension}`;
    return this.withStorageOperation(storageKey, () => this.store.withStorageKeyLock(storageKey, async () => {
      if (await this.store.hasStorageDelete(storageKey)) {
        throw new ArtifactRequestError(503, "screenshot_storage_delete_pending");
      }
      const reservation = await this.store.withIdentity(identity, async (scoped) => {
        if (!await scoped.ensureUploadTarget(vaultId, meetingId)) throw missingMeetingConflict(meetingId);
        const existing = await scoped.getScreenshot(vaultId, meetingId, screenshotId);
        if (existing) return { existing, created: false };
        const record: SyncScreenshotRecord = {
          screenshotId,
          vaultId,
          meetingId,
          capturedAt: capturedAt.data,
          contentType: upload.contentType,
          storageKey,
          contentLength: upload.contentLength,
          contentHash,
          ocrText: null,
          caption: null,
          revision: 0,
        };
        return await scoped.createScreenshot(record) ? { existing: record, created: true } : null;
      });
      if (!reservation) throw new ArtifactRequestError(409, "screenshot_id_conflict");
      if (
        reservation.existing.vaultId !== vaultId
        || reservation.existing.meetingId !== meetingId
        || reservation.existing.contentType !== upload.contentType
        || reservation.existing.storageKey !== storageKey
        || reservation.existing.contentLength !== upload.contentLength
        || reservation.existing.contentHash !== contentHash
      ) {
        throw new ArtifactRequestError(409, "screenshot_id_conflict");
      }
      if (!reservation.created && await this.storageCall(() => storage.exists(storageKey, request.signal))) {
        const actualHash = await sha256Stream(request.body);
        if (actualHash !== contentHash) throw new ArtifactRequestError(409, "screenshot_content_hash_mismatch");
        const stored = await this.storageCall(() => storage.read(storageKey, "GET", request));
        if (await sha256Stream(stored.body) !== contentHash) {
          try {
            await storage.delete(storageKey);
          } catch {
            await this.store.enqueueStorageDelete(storageKey);
            this.scheduleStorageDeletes();
          }
          throw new ArtifactRequestError(503, "screenshot_stored_content_hash_mismatch");
        }
        return reservation.existing;
      }
      try {
        const uploadBody = sha256Passthrough(request.body);
        const [, actualHash] = await Promise.all([
          this.storageCall(() => storage.put(
            storageKey,
            uploadBody.body,
            upload.contentLength,
            upload.contentType,
            request.signal,
          )),
          uploadBody.digest,
        ]);
        if (actualHash !== contentHash) throw new ArtifactRequestError(409, "screenshot_content_hash_mismatch");
        const current = await this.store.withIdentity(identity, async (scoped) => {
          if (!await scoped.ensureUploadTarget(vaultId, meetingId)) throw missingMeetingConflict(meetingId);
          return scoped.getScreenshot(vaultId, meetingId, screenshotId);
        });
        if (!current
          || current.storageKey !== storageKey
          || current.contentType !== upload.contentType
          || current.contentLength !== upload.contentLength
          || current.contentHash !== contentHash) {
          throw new ArtifactRequestError(409, "screenshot_id_conflict");
        }
        return current;
      } catch (error) {
        try {
          await storage.delete(storageKey);
        } catch {
          await this.store.enqueueStorageDelete(storageKey);
          this.scheduleStorageDeletes();
        }
        if (reservation.created) {
          await this.store.withIdentity(
            identity,
            (scoped) => scoped.deleteScreenshot(vaultId, screenshotId, storageKey),
          );
        }
        throw error;
      }
    }));
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

  async readScreenshot(
    identity: Identity,
    vaultId: string,
    meetingId: string,
    screenshotId: string,
    method: ArtifactReadMethod,
    request: Request,
  ): Promise<Response> {
    const storage = this.requireStorage();
    const screenshot = await this.store.withIdentity(identity, async (scoped) => {
      if (!await scoped.getMeeting(vaultId, meetingId)) return null;
      return scoped.getScreenshot(vaultId, meetingId, screenshotId, true);
    });
    if (!screenshot) throw new ArtifactRequestError(404, "screenshot_not_found");
    const requestedVariant = new URL(request.url).searchParams.get("variant") ?? "original";
    if (!["original", "thumbnail"].includes(requestedVariant)) {
      throw new ArtifactRequestError(400, "invalid_screenshot_variant");
    }
    if (requestedVariant !== "original" && this.screenshotTransformer) {
      const variant = requestedVariant as ScreenshotVariant;
      try {
        const bytes = await this.ensureScreenshotVariant(identity, screenshot, variant);
        const current = await this.store.withIdentity(identity, (scoped) =>
          scoped.getScreenshot(vaultId, meetingId, screenshotId, true));
        if (!current || current.contentHash !== screenshot.contentHash) {
          throw new ArtifactRequestError(404, "screenshot_not_found");
        }
        const upstream = bytes
          ? new Response(bytes, { headers: { "content-length": String(bytes.byteLength) } })
          : await this.storageCall(() => storage.read(screenshotVariantKey(screenshot.storageKey, variant), method, request));
        const headers = this.screenshotHeaders(screenshot, upstream, variant);
        return new Response(method === "HEAD" ? null : upstream.body, { status: upstream.status, headers });
      } catch {
        // An unsupported or failed conversion must not make a durably stored original unreadable.
        // A shared job may also have lost its initiator's access; authorize this caller below.
      }
    }
    const current = await this.store.withIdentity(identity, (scoped) =>
      scoped.getScreenshot(vaultId, meetingId, screenshotId, true));
    if (!current || current.contentHash !== screenshot.contentHash || current.storageKey !== screenshot.storageKey) {
      throw new ArtifactRequestError(404, "screenshot_not_found");
    }
    const upstream = await this.storageCall(() => storage.read(screenshot.storageKey, method, request));
    const headers = this.screenshotHeaders(screenshot, upstream, "original");
    return new Response(method === "HEAD" ? null : upstream.body, { status: upstream.status, headers });
  }

  private screenshotHeaders(screenshot: SyncScreenshotRecord, upstream: Response, variant: ScreenshotVariant | "original") {
    const headers = new Headers({
      "content-security-policy": "sandbox allow-scripts",
      "content-type": variant === "original" ? screenshot.contentType : "image/webp",
      "x-content-type-options": "nosniff",
      "cache-control": "private, no-cache",
      "x-dahlia-image-variant": variant,
    });
    if (screenshot.contentHash) headers.set("x-dahlia-original-sha256", screenshot.contentHash);
    for (const name of ["accept-ranges", "content-length", "content-range", "etag", "last-modified"]) {
      const value = upstream.headers.get(name);
      if (value) headers.set(name, value);
    }
    return headers;
  }

  private async warmThumbnail(identity: Identity, vaultId: string, meetingId: string, screenshotId: string) {
    try {
      const screenshot = await this.store.withIdentity(identity, (scoped) =>
        scoped.getScreenshot(vaultId, meetingId, screenshotId, true));
      if (screenshot) await this.ensureScreenshotVariant(identity, screenshot, "thumbnail");
    } catch {
      // The read path retries. Thumbnail warming is not part of transaction durability.
    }
  }

  private ensureScreenshotVariant(identity: Identity, screenshot: SyncScreenshotRecord, variant: ScreenshotVariant) {
    const key = screenshotVariantKey(screenshot.storageKey, variant);
    const existing = this.variantJobs.get(key);
    if (existing) return existing;
    if (this.variantJobs.size >= 32) throw new ArtifactRequestError(503, "screenshot_transform_busy");
    const job = this.generateScreenshotVariant(identity, screenshot, variant)
      .finally(() => this.variantJobs.delete(key));
    this.variantJobs.set(key, job);
    return job;
  }

  private async generateScreenshotVariant(identity: Identity, screenshot: SyncScreenshotRecord, variant: ScreenshotVariant) {
    if (this.activeVariants >= 2) await new Promise<void>((resolve) => this.variantWaiters.push(resolve));
    else this.activeVariants += 1;
    try {
      return await this.withStorageOperation(screenshot.storageKey, () => this.store.withStorageKeyLock(
        screenshot.storageKey,
        async () => {
          const storage = this.requireStorage();
          const key = screenshotVariantKey(screenshot.storageKey, variant);
          const request = new Request("https://dahlia.invalid/", { signal: AbortSignal.timeout(20_000) });
          const deleteVariantOrEnqueueRetry = async () => {
            try {
              await storage.delete(key);
            } catch {
              await this.store.enqueueStorageDelete(key);
              this.scheduleStorageDeletes();
            }
          };
          const isCurrent = async () => {
            if (await this.store.hasStorageDelete(screenshot.storageKey)) return false;
            const current = await this.store.withIdentity(identity, (scoped) =>
              scoped.getScreenshot(screenshot.vaultId, screenshot.meetingId, screenshot.screenshotId, true));
            return current?.contentHash === screenshot.contentHash && current?.storageKey === screenshot.storageKey;
          };
          if (!await isCurrent()) throw new ArtifactRequestError(404, "screenshot_not_found");
          if (await this.store.hasStorageDelete(key)) throw new ArtifactRequestError(503, "screenshot_cache_delete_pending");
          if (await storage.exists(key, request.signal)) return undefined;
          const original = await storage.read(screenshot.storageKey, "GET", request);
          if (!original.ok || !original.body) throw new Error("screenshot_original_unavailable");
          const bytes = await this.screenshotTransformer!(original.body, SCREENSHOT_VARIANTS[variant]);
          if (!await isCurrent()) throw new ArtifactRequestError(404, "screenshot_not_found");
          try {
            await storage.put(key, bytes, bytes.byteLength, "image/webp", request.signal);
          } catch {
            // Serve the generated image even when the rebuildable cache cannot be written.
            await deleteVariantOrEnqueueRetry();
          }
          if (!await isCurrent()) {
            // Also covers SQLite instances, where cross-process advisory locks are unavailable.
            await deleteVariantOrEnqueueRetry();
            throw new ArtifactRequestError(404, "screenshot_not_found");
          }
          return bytes;
        },
      ));
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

  getMeeting(identity: Identity, vaultId: string, meetingId: string) {
    return this.store.withIdentity(identity, (scoped) => scoped.getMeeting(vaultId, meetingId));
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

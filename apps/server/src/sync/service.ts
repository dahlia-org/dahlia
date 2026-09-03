import { z } from "zod";

import type { Identity } from "../auth/identity";
import { DEFAULT_ARTIFACT_MAX_BYTES } from "../config";
import { ObjectStorageError, type ArtifactReadMethod, type ObjectStorage } from "../artifacts/storage";
import { ArtifactRequestError, parseUpload } from "../artifacts/upload";
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
import { decodeSyncCursor, encodeSyncCursor, SyncTransactionError } from "./store";

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
const transcriptSegmentSchema = z.object({
  segmentId: uuidSchema,
  startTime: dateSchema,
  endTime: nullableDateSchema,
  text: z.string().max(100_000),
  isConfirmed: z.literal(true),
  audioSource: z.enum(["mic", "system"]).nullable(),
  speakerLabel: z.string().max(200).nullable(),
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
const QUERY_EMBEDDING_DEADLINE_MS = 2_000;
const QUERY_EMBEDDING_CONCURRENCY = 8;
const permissionPrincipalSchema = z.string().trim().min(1).max(200);
export const SYNC_READ_PAGE_SIZE = 200;
const TRANSCRIPT_READ_PAGE_SIZE = 10_000;
const TRANSCRIPT_PATCH_ITEM_LIMIT = 50_000;
const TRANSCRIPT_PATCH_CHUNK_LIMIT = 100;
const meetingCursorSchema = z.tuple([dateSchema, uuidSchema]);
const screenshotCursorSchema = z.tuple([dateSchema, uuidSchema]);
const transcriptCursorSchema = z.tuple([dateSchema, uuidSchema]);
const uuidV7Schema = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
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
  "vault:create": z.object({ name: z.string().trim().min(1).max(500), createdAt: dateSchema }).strict(),
  "vault:update": z.object({ name: z.string().trim().min(1).max(500) }).strict(),
  "vault:reset": z.object({}).strict(),
  "project:create": z.object({ parentProjectId: uuidSchema.nullable(), name: projectNameSchema, description: z.string().max(20_000).default(""), projectType: projectTypeSchema.nullable(), createdAt: dateSchema }).strict(),
  "project:update": z.object({ parentProjectId: uuidSchema.nullable(), name: projectNameSchema, description: z.string().max(20_000).default(""), projectType: projectTypeSchema.nullable() }).strict(),
  "project:delete": z.object({}).strict(),
  "meeting:create": z.object({ projectId: uuidSchema.nullable(), name: z.string().max(500), description: z.string().max(20_000).default(""), status: z.string().max(100), duration: z.number().finite().nonnegative().nullable(), recordingStartedAt: nullableDateSchema, createdAt: dateSchema, updatedAt: dateSchema }).strict(),
  "meeting:update": z.object({ projectId: uuidSchema.nullable(), name: z.string().max(500), description: z.string().max(20_000).default(""), status: z.string().max(100), duration: z.number().finite().nonnegative().nullable(), recordingStartedAt: nullableDateSchema, updatedAt: dateSchema }).strict(),
  "meeting:delete": z.object({}).strict(),
  "summary:upsert": z.object({ title: z.string().max(500), document: z.string().max(8 * 1024 * 1024), createdAt: dateSchema }).strict(),
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

export class MeetingSyncService {
  private readonly activeQueryEmbeddingUsers = new Set<string>();
  private readonly screenshotUploads = new Map<string, Promise<void>>();
  private storageDeleteDrain?: Promise<void>;
  private storageDeleteRetry?: ReturnType<typeof setTimeout>;

  constructor(
    private readonly store: MeetingSyncStore,
    private readonly storage?: ObjectStorage,
    private readonly tokenizer: SearchTokenizer = createIntlSearchTokenizer(),
    private readonly embedder?: SearchEmbedder,
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

  async commitTransaction(identity: Identity, body: unknown) {
    this.requireWritableIdentity(identity);
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
    const response = await this.store.withIdentity(identity, async (scoped) => {
      const meetings = new Map<string, Awaited<ReturnType<IdentitySyncStore["getMeeting"]>>>();
      const prepared = [] as SyncTransaction["operations"];
      for (const operation of operations) {
        const data = { ...(operation.data ?? {}) };
        if ((operation.entity === "meeting" && operation.action !== "delete") || operation.entity === "summary") {
          let meeting = meetings.get(operation.entityId);
          if (meeting === undefined) {
            meeting = operation.entity === "meeting" && operation.action === "create"
              ? null
              : await scoped.getMeeting(parsed.data.vaultId, operation.entityId);
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
            vaultId: parsed.data.vaultId,
            projectId: operation.entity === "meeting" ? data.projectId as string | null : meeting?.projectId ?? null,
            name,
            description,
            status: operation.entity === "meeting" ? String(data.status) : meeting?.status ?? "",
            duration: operation.entity === "meeting" ? data.duration as number | null : meeting?.duration ?? null,
            recordingStartedAt: operation.entity === "meeting" ? data.recordingStartedAt as Date | null : meeting?.recordingStartedAt ?? null,
            createdAt: operation.entity === "meeting" && operation.action === "create" ? data.createdAt as Date : meeting?.createdAt ?? parsed.data.createdAt,
            updatedAt: operation.entity === "meeting" ? data.updatedAt as Date : meeting?.updatedAt ?? parsed.data.createdAt,
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
      const storageKeys = await this.store.claimStorageDeletes(SCREENSHOT_DELETE_BATCH_SIZE);
      if (storageKeys.length === 0) return;
      for (const storageKey of storageKeys) {
        try {
          await this.storageCall(() => this.storage!.delete(storageKey));
          await this.store.completeStorageDelete(storageKey);
        } catch (error) {
          await this.store.failStorageDelete(
            storageKey,
            error instanceof ObjectStorageError ? error.code : "artifact_storage_unavailable",
          );
          this.scheduleStorageDeleteRetry();
        }
      }
    }
  }

  async listChanges(identity: Identity, vaultId: string, cursor?: string) {
    const after = cursor ? decodeSyncCursor(cursor) : 0;
    const rows = await this.store.withIdentity(identity, (scoped) => scoped.listChanges(
      vaultId,
      after,
      SYNC_CHANGE_PAGE_SIZE + 1,
    ));
    const items = rows.slice(0, SYNC_CHANGE_PAGE_SIZE);
    const last = items.at(-1);
    return {
      items,
      cursor: encodeSyncCursor(last?.sequence ?? after),
      hasMore: rows.length > SYNC_CHANGE_PAGE_SIZE,
    };
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
    if (!accepted) throw new ArtifactRequestError(409, "sync_target_conflict");
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
    return this.withScreenshotUpload(storageKey, async () => {
      const reservation = await this.store.withIdentity(identity, async (scoped) => {
      if (!await scoped.ensureUploadTarget(vaultId, meetingId)) return null;
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
        return reservation.existing;
      }
      try {
        const [storageBody, digestBody] = request.body?.tee() ?? [new Uint8Array(), new Uint8Array()];
        const [, actualHash] = await Promise.all([
          this.storageCall(() => storage.put(
            storageKey,
            storageBody,
            upload.contentLength,
            upload.contentType,
            request.signal,
          )),
          sha256Stream(digestBody),
        ]);
        if (actualHash !== contentHash) throw new ArtifactRequestError(409, "screenshot_content_hash_mismatch");
        return reservation.existing;
      } catch (error) {
        if (reservation.created) {
          try {
            await storage.delete(storageKey);
          } catch {
            await this.store.enqueueStorageDelete(storageKey);
            this.scheduleStorageDeletes();
          }
          await this.store.withIdentity(
            identity,
            (scoped) => scoped.deleteScreenshot(vaultId, screenshotId, storageKey),
          );
        }
        throw error;
      }
    });
  }

  private async withScreenshotUpload<T>(storageKey: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.screenshotUploads.get(storageKey);
    let release!: () => void;
    const current = new Promise<void>((resolve) => { release = resolve; });
    this.screenshotUploads.set(storageKey, current);
    await previous;
    try {
      return await operation();
    } finally {
      release();
      if (this.screenshotUploads.get(storageKey) === current) this.screenshotUploads.delete(storageKey);
    }
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
    const upstream = await this.storageCall(() => storage.read(screenshot.storageKey, method, request));
    const headers = new Headers({
      "content-security-policy": "sandbox allow-scripts",
      "content-type": screenshot.contentType,
      "x-content-type-options": "nosniff",
    });
    for (const name of ["accept-ranges", "content-length", "content-range", "etag", "last-modified"]) {
      const value = upstream.headers.get(name);
      if (value) headers.set(name, value);
    }
    return new Response(method === "HEAD" ? null : upstream.body, { status: upstream.status, headers });
  }

  listVaults(identity: Identity) {
    return this.store.withIdentity(identity, (scoped) => scoped.listVaults());
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
  ) {
    const search = this.parseSearchQuery(query);
    if (search?.tokens.length && this.embedder
      && !await this.store.withIdentity(identity, (scoped) => scoped.getVault(vaultId))) return { items: [] };
    if (search) {
      return {
        items: await this.search(identity, search, (scoped, prepared) =>
          scoped.listMeetings(vaultId, prepared, SYNC_READ_PAGE_SIZE, projectId),
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

  async deleteMeeting(identity: Identity, vaultId: string, meetingId: string): Promise<boolean> {
    const screenshots = await this.store.withIdentity(
      identity,
      (scoped) => scoped.beginMeetingDeletion(vaultId, meetingId, SCREENSHOT_DELETE_BATCH_SIZE),
    );
    if (screenshots === null) throw new ArtifactRequestError(404, "meeting_not_found");
    await this.deleteScreenshots(identity, screenshots);
    return this.store.withIdentity(identity, (scoped) => scoped.finishMeetingDeletion(vaultId, meetingId));
  }

  async deleteVault(identity: Identity, vaultId: string): Promise<boolean> {
    const screenshots = await this.store.withIdentity(
      identity,
      (scoped) => scoped.beginVaultDeletion(vaultId, SCREENSHOT_DELETE_BATCH_SIZE),
    );
    if (screenshots === null) throw new ArtifactRequestError(404, "vault_not_found");
    await this.deleteScreenshots(identity, screenshots);
    return this.store.withIdentity(identity, (scoped) => scoped.finishVaultDeletion(vaultId));
  }

  private requireWritableIdentity(identity: Identity): void {
    if (identity.impersonated) throw new ArtifactRequestError(403, "impersonated_session_read_only");
  }

  private async deleteScreenshots(identity: Identity, screenshots: SyncScreenshotRecord[]): Promise<void> {
    if (screenshots.length === 0) return;
    const storage = this.requireStorage();
    for (const screenshot of screenshots) {
      await this.storageCall(() => storage.delete(screenshot.storageKey));
      await this.store.withIdentity(
        identity,
        (scoped) => scoped.deleteScreenshot(screenshot.vaultId, screenshot.screenshotId, screenshot.storageKey),
      );
    }
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

async function sha256Stream(value: ReadableStream<Uint8Array> | Uint8Array | null): Promise<string> {
  const bytes = value instanceof Uint8Array
    ? value
    : new Uint8Array(await new Response(value).arrayBuffer());
  const digest = await crypto.subtle.digest(
    "SHA-256",
    bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer,
  );
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

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
  SyncManifest,
  SyncScreenshotRecord,
  SyncSearchQuery,
  VaultPrincipalType,
} from "./types";

const uuidSchema = z.uuid().transform((value) => value.toLowerCase());
const generationSchema = z.string().regex(/^[0-9a-f]{64}$/);
const dateSchema = z.iso.datetime().transform((value) => new Date(value));
const nullableDateSchema = dateSchema.nullable();
const projectNameSchema = z.string().trim().min(1).refine((value) =>
  ![".", ".."].includes(value)
  && ![".", "_"].includes(value[0] ?? "")
  && ![...value].some((character) => "/:".includes(character) || character.charCodeAt(0) <= 31 || character.charCodeAt(0) === 127)
  && new TextEncoder().encode(value).byteLength <= 255,
);
const projectTypeSchema = z.enum(["customer", "internal", "personal", "undefined"]);
const vaultManifestSchema = z.object({
  name: z.string().trim().min(1).max(500),
  createdAt: dateSchema,
  projects: z.array(z.object({
    projectId: uuidSchema,
    parentProjectId: uuidSchema.nullable(),
    name: projectNameSchema,
    description: z.string().max(20_000).default(""),
    projectType: projectTypeSchema.nullable(),
    revision: z.number().int().min(1),
    createdAt: dateSchema,
  }).strict()).max(10_000),
}).strict();
const transcriptSegmentSchema = z.object({
  segmentId: uuidSchema,
  startTime: dateSchema,
  endTime: nullableDateSchema,
  text: z.string(),
  isConfirmed: z.boolean(),
  audioSource: z.enum(["mic", "system"]).nullable(),
  speakerLabel: z.string().max(200).nullable(),
}).strict();
const transcriptChunkSchema = z.object({
  segments: z.array(transcriptSegmentSchema).max(500),
}).strict();
const manifestSchema = z.object({
  projectId: uuidSchema.nullable(),
  name: z.string().max(500),
  description: z.string().max(20_000).default(""),
  status: z.string().max(100),
  duration: z.number().finite().nonnegative().nullable(),
  recordingStartedAt: nullableDateSchema,
  createdAt: dateSchema,
  updatedAt: dateSchema,
  summary: z.object({
    title: z.string(),
    document: z.string(),
    createdAt: dateSchema,
  }).strict().nullable(),
  activeTranscriptGeneration: generationSchema.nullable(),
  screenshots: z.array(z.object({
    screenshotId: uuidSchema,
    capturedAt: dateSchema,
    ocrText: z.string().nullable(),
    caption: z.string().nullable(),
  }).strict()).max(10_000),
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
const SCREENSHOT_PROJECTION_BATCH_SIZE = 64;
const permissionPrincipalSchema = z.string().trim().min(1).max(200);
export const SYNC_READ_PAGE_SIZE = 200;
const meetingCursorSchema = z.tuple([dateSchema, uuidSchema]);
const screenshotCursorSchema = z.tuple([dateSchema, uuidSchema]);

export class MeetingSyncService {
  private readonly activeQueryEmbeddingUsers = new Set<string>();

  constructor(
    private readonly store: MeetingSyncStore,
    private readonly storage?: ObjectStorage,
    private readonly tokenizer: SearchTokenizer = createIntlSearchTokenizer(),
    private readonly embedder?: SearchEmbedder,
  ) {}

  parseId(value: string): string {
    if (value !== value.toLowerCase()) throw new ArtifactRequestError(400, "invalid_sync_id");
    const parsed = uuidSchema.safeParse(value);
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_sync_id");
    return parsed.data;
  }

  parseGeneration(value: string): string {
    const parsed = generationSchema.safeParse(value);
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_transcript_generation");
    return parsed.data;
  }

  parsePermissionPrincipal(value: string): string {
    const parsed = permissionPrincipalSchema.safeParse(value);
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_sync_share_target");
    return parsed.data;
  }

  async commitVaultManifest(identity: Identity, vaultId: string, body: unknown): Promise<void> {
    const parsed = vaultManifestSchema.safeParse(body);
    if (!parsed.success || !validProjectHierarchy(parsed.data?.projects ?? [])) {
      throw new ArtifactRequestError(400, "invalid_vault_manifest");
    }
    const accepted = await this.store.withIdentity(identity, (scoped) => scoped.commitVaultManifest({
      vaultId,
      ...parsed.data,
      projects: parsed.data.projects.map((project) => ({ ...project, vaultId })),
    }));
    if (!accepted) throw new ArtifactRequestError(404, "vault_not_found");
  }

  async commitManifest(identity: Identity, vaultId: string, meetingId: string, body: unknown): Promise<void> {
    const parsed = manifestSchema.safeParse(body);
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_sync_manifest");
    const screenshotIds = parsed.data.screenshots.map(({ screenshotId }) => screenshotId);
    if (new Set(screenshotIds).size !== screenshotIds.length || screenshotIds.includes(meetingId)) {
      throw new ArtifactRequestError(400, "invalid_sync_manifest");
    }
    const summaryDocument = parsed.data.summary?.document ?? null;
    const summaryText = summarySearchableText(summaryDocument);
    const embeddingText = summaryText.trim() || null;
    const screenshots: SyncManifest["screenshots"] = [];
    for (let offset = 0; offset < parsed.data.screenshots.length; offset += SCREENSHOT_PROJECTION_BATCH_SIZE) {
      const batch = parsed.data.screenshots.slice(offset, offset + SCREENSHOT_PROJECTION_BATCH_SIZE);
      screenshots.push(...await Promise.all(batch.map(async (screenshot) => {
        const screenshotEmbeddingText = [screenshot.ocrText, screenshot.caption]
          .filter((value): value is string => Boolean(value?.trim())).join("\n") || null;
        return {
          ...screenshot,
          searchText: createSearchText(this.tokenizer, [screenshot.ocrText, screenshot.caption]),
          embeddingText: screenshotEmbeddingText,
          embeddingContentHash: await embeddingContentHash(screenshotEmbeddingText),
        };
      })));
    }
    const manifest: SyncManifest = {
      vaultId,
      meetingId,
      projectId: parsed.data.projectId,
      name: parsed.data.name,
      description: parsed.data.description,
      status: parsed.data.status,
      duration: parsed.data.duration,
      recordingStartedAt: parsed.data.recordingStartedAt,
      createdAt: parsed.data.createdAt,
      updatedAt: parsed.data.updatedAt,
      summaryTitle: parsed.data.summary?.title ?? null,
      summaryDocument,
      summaryCreatedAt: parsed.data.summary?.createdAt ?? null,
      activeTranscriptGeneration: parsed.data.activeTranscriptGeneration,
      searchText: createSearchText(this.tokenizer, [
        parsed.data.name,
        parsed.data.description,
        summaryText,
      ]),
      embeddingText,
      embeddingContentHash: await embeddingContentHash(embeddingText),
      screenshots,
    };
    const result = await this.store.withIdentity(identity, (scoped) => scoped.commitManifest(manifest));
    if (result.missingScreenshotContent) throw new ArtifactRequestError(409, "screenshot_content_missing");
    if (!result.committed) throw new ArtifactRequestError(409, "sync_target_conflict");
    await this.deleteScreenshots(identity, result.obsoleteScreenshots);
  }

  async putTranscriptChunk(
    identity: Identity,
    vaultId: string,
    meetingId: string,
    generation: string,
    body: unknown,
  ): Promise<void> {
    const parsed = transcriptChunkSchema.safeParse(body);
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_transcript_chunk");
    const accepted = await this.store.withIdentity(identity, (scoped) => scoped.putTranscriptChunk(
      vaultId,
      meetingId,
      generation,
      parsed.data.segments,
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
    const storageKey = `meetings/${meetingId}/screenshots/${screenshotId}.${extension}`;

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
        ocrText: null,
        caption: null,
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
    ) {
      throw new ArtifactRequestError(409, "screenshot_id_conflict");
    }
    if (!reservation.created && await this.storageCall(() => storage.exists(storageKey, request.signal))) {
      return reservation.existing;
    }
    try {
      await this.storageCall(() => storage.put(
        storageKey,
        request.body ?? new Uint8Array(),
        upload.contentLength,
        upload.contentType,
        request.signal,
      ));
      return reservation.existing;
    } catch (error) {
      if (reservation.created) {
        await this.store.withIdentity(
          identity,
          (scoped) => scoped.deleteScreenshot(vaultId, screenshotId, storageKey),
        );
        await storage.delete(storageKey).catch(() => undefined);
      }
      throw error;
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

  listTranscript(identity: Identity, vaultId: string, meetingId: string) {
    return this.store.withIdentity(identity, (scoped) => scoped.listTranscript(vaultId, meetingId, 10_000));
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

function validProjectHierarchy(projects: z.infer<typeof vaultManifestSchema>["projects"]): boolean {
  const byId = new Map(projects.map((project) => [project.projectId, project]));
  if (byId.size !== projects.length) return false;
  const siblingNames = new Set<string>();
  for (const project of projects) {
    const parent = project.parentProjectId ? byId.get(project.parentProjectId) : undefined;
    if (project.parentProjectId && (!parent || parent.parentProjectId)) return false;
    if ((project.parentProjectId === null) !== (project.projectType !== null)) return false;
    const key = `${project.parentProjectId ?? "root"}\u0000${project.name.normalize("NFKC").toLowerCase()}`;
    if (siblingNames.has(key)) return false;
    siblingNames.add(key);
  }
  return true;
}

async function embeddingContentHash(text: string | null): Promise<string | null> {
  if (!text) return null;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

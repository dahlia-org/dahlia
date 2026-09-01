import { z } from "zod";

import type { Identity } from "../auth/identity";
import type { ArtifactRecord, AuthStore } from "../auth/store";
import { DEFAULT_ARTIFACT_MAX_BYTES, type AppConfig } from "../config";
import { ObjectStorageError, type ArtifactReadMethod, type ObjectStorage } from "./storage";

const FORWARDED_RESPONSE_HEADERS = [
  "accept-ranges",
  "content-length",
  "content-range",
  "etag",
  "last-modified",
] as const;

const artifactIdSchema = z.uuidv7();
const visibilitySchema = z.object({ visibility: z.enum(["private", "public"]) }).strict();
const ID_GENERATION_ATTEMPTS = 3;
export const ARTIFACT_LIST_PAGE_SIZE = 50;
export const ARTIFACT_METADATA_MEDIA_TYPE = "application/vnd.dahlia.artifact+json";

interface ArtifactUpload {
  contentLength: number;
  contentType: string;
  extension: string;
}

export class ArtifactRequestError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
  }
}

export class ArtifactService {
  constructor(
    private readonly config: AppConfig,
    private readonly store: Pick<
      AuthStore,
      "listArtifacts" | "getArtifact" | "createArtifact" | "commitArtifactStorage" | "updateArtifactVisibility"
      | "deleteArtifact"
    >,
    private readonly storage?: ObjectStorage,
  ) {}

  parseId(value: string): string {
    if (value !== value.toLowerCase()) throw new ArtifactRequestError(400, "invalid_artifact_id");
    const parsed = artifactIdSchema.safeParse(value);
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_artifact_id");
    return parsed.data;
  }

  async get(id: string): Promise<ArtifactRecord | null> {
    this.requireStorage();
    return this.metadata(() => this.store.getArtifact(id));
  }

  async list(ownerWorkspaceId: string, cursor?: string): Promise<{
    items: ArtifactRecord[];
    nextCursor?: string;
  }> {
    const parsedCursor = cursor === undefined ? undefined : this.parseId(cursor);
    const records = await this.metadata(() => this.store.listArtifacts(
      ownerWorkspaceId,
      parsedCursor,
      ARTIFACT_LIST_PAGE_SIZE + 1,
    ));
    const items = records.slice(0, ARTIFACT_LIST_PAGE_SIZE);
    return {
      items,
      ...(records.length > ARTIFACT_LIST_PAGE_SIZE ? { nextCursor: items.at(-1)!.id } : {}),
    };
  }

  async create(identity: Identity, request: Request): Promise<ArtifactRecord> {
    const storage = this.requireStorage();
    const upload = parseUpload(request, this.config.artifactMaxBytes ?? DEFAULT_ARTIFACT_MAX_BYTES);
    for (let attempt = 0; attempt < ID_GENERATION_ATTEMPTS; attempt += 1) {
      const id = uuidV7();
      const artifact = await this.metadata(() => this.store.createArtifact({
        id,
        ownerWorkspaceId: identity.workspaceId,
        contentType: upload.contentType,
      }));
      if (!artifact) continue;
      const storageKey = artifactVersionStorageKey(id, upload.extension);
      try {
        return await this.write(artifact, request, upload, storage, storageKey);
      } catch (error) {
        await this.cleanupFailedCreation(artifact, storage, storageKey);
        throw error;
      }
    }
    throw new ArtifactRequestError(503, "artifact_id_generation_failed");
  }

  async put(id: string, identity: Identity, request: Request): Promise<ArtifactRecord> {
    const storage = this.requireStorage();
    const upload = parseUpload(request, this.config.artifactMaxBytes ?? DEFAULT_ARTIFACT_MAX_BYTES);
    const artifact = await this.getOwned(id, identity);
    if (artifact.contentType !== upload.contentType) {
      throw new ArtifactRequestError(409, "artifact_content_type_mismatch");
    }
    return this.write(artifact, request, upload, storage, artifactVersionStorageKey(id, upload.extension));
  }

  private async write(
    artifact: ArtifactRecord,
    request: Request,
    upload: ArtifactUpload,
    storage: ObjectStorage,
    storageKey: string,
  ): Promise<ArtifactRecord> {
    const body = request.body ?? new Uint8Array();
    const previousStorageKey = artifact.storageKey;
    await this.storageCall(() => storage.put(
      storageKey,
      body,
      upload.contentLength,
      upload.contentType,
      request.signal,
    ));
    const updated = await this.metadata(() => this.store.commitArtifactStorage(
      artifact.id,
      artifact.ownerWorkspaceId,
      previousStorageKey,
      storageKey,
    ));
    if (!updated) {
      await this.storageCall(() => storage.delete(storageKey));
      const current = await this.get(artifact.id);
      if (!current || current.ownerWorkspaceId !== artifact.ownerWorkspaceId) {
        throw new ArtifactRequestError(404, "artifact_not_found");
      }
      throw new ArtifactRequestError(409, "artifact_write_conflict");
    }
    if (previousStorageKey) await this.cleanupReplacedObject(storage, previousStorageKey);
    return updated;
  }

  async read(
    artifact: ArtifactRecord,
    method: ArtifactReadMethod,
    request: Request,
  ): Promise<Response> {
    const storage = this.requireStorage();
    const storageKey = artifact.storageKey;
    if (!storageKey) throw new ArtifactRequestError(404, "artifact_not_found");
    const upstream = await this.storageCall(() => storage.read(
      storageKey,
      method,
      request,
    ));
    const headers = new Headers({
      "content-security-policy": "sandbox allow-scripts",
      "content-type": artifact.contentType,
    });
    for (const name of FORWARDED_RESPONSE_HEADERS) {
      const value = upstream.headers.get(name);
      if (value) headers.set(name, value);
    }
    return new Response(method === "HEAD" ? null : upstream.body, {
      status: upstream.status,
      headers,
    });
  }

  async setVisibility(
    id: string,
    identity: Identity,
    body: unknown,
    signal?: AbortSignal,
  ): Promise<ArtifactRecord> {
    const parsed = visibilitySchema.safeParse(body);
    if (!parsed.success) throw new ArtifactRequestError(400, "invalid_artifact_visibility");
    const artifact = await this.getOwned(id, identity);
    if (parsed.data.visibility === "public" && artifact.visibility !== "public") {
      const storageKey = artifact.storageKey;
      const exists = storageKey
        ? await this.storageCall(() => this.requireStorage().exists(storageKey, signal))
        : false;
      if (!exists) throw new ArtifactRequestError(409, "artifact_not_uploaded");
    }
    const updated = await this.metadata(() => this.store.updateArtifactVisibility(
      id,
      identity.workspaceId,
      parsed.data.visibility,
    ));
    if (!updated) throw new ArtifactRequestError(404, "artifact_not_found");
    return updated;
  }

  async delete(id: string, identity: Identity, signal?: AbortSignal): Promise<ArtifactRecord> {
    const artifact = await this.getOwned(id, identity);
    const storageKey = artifact.storageKey;
    if (storageKey) {
      await this.storageCall(() => this.requireStorage().delete(storageKey, signal));
    }
    const deleted = await this.metadata(() => this.store.deleteArtifact(
      id,
      identity.workspaceId,
      storageKey,
    ));
    if (deleted) return artifact;
    const current = await this.get(id);
    if (!current || current.ownerWorkspaceId !== identity.workspaceId) {
      throw new ArtifactRequestError(404, "artifact_not_found");
    }
    throw new ArtifactRequestError(409, "artifact_write_conflict");
  }

  async getOwned(id: string, identity: Identity): Promise<ArtifactRecord> {
    const artifact = await this.get(id);
    if (!artifact || artifact.ownerWorkspaceId !== identity.workspaceId) {
      throw new ArtifactRequestError(404, "artifact_not_found");
    }
    return artifact;
  }

  private requireStorage(): ObjectStorage {
    if (!this.storage) throw new ArtifactRequestError(503, "artifact_storage_not_configured");
    return this.storage;
  }

  private async metadata<T>(operation: () => Promise<T>): Promise<T> {
    try {
      return await operation();
    } catch {
      throw new ArtifactRequestError(503, "artifact_metadata_unavailable");
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

  private async cleanupReplacedObject(storage: ObjectStorage, key: string): Promise<void> {
    try {
      await storage.delete(key);
    } catch {
      console.error(JSON.stringify({ level: "error", event: "object_storage_cleanup_failed" }));
    }
  }

  private async cleanupFailedCreation(
    artifact: ArtifactRecord,
    storage: ObjectStorage,
    storageKey: string,
  ): Promise<void> {
    let current: ArtifactRecord | null;
    try {
      current = await this.store.getArtifact(artifact.id);
    } catch {
      console.error(JSON.stringify({ level: "error", event: "artifact_creation_cleanup_failed" }));
      return;
    }
    if (current && (
      current.ownerWorkspaceId !== artifact.ownerWorkspaceId
      || (current.storageKey !== null && current.storageKey !== storageKey)
    )) {
      console.error(JSON.stringify({ level: "error", event: "artifact_creation_cleanup_failed" }));
      return;
    }
    try {
      await storage.delete(storageKey);
    } catch {
      console.error(JSON.stringify({ level: "error", event: "artifact_creation_cleanup_failed" }));
      return;
    }
    if (!current) return;
    try {
      const deleted = await this.store.deleteArtifact(
        artifact.id,
        artifact.ownerWorkspaceId,
        current.storageKey,
      );
      if (!deleted) {
        console.error(JSON.stringify({ level: "error", event: "artifact_creation_cleanup_failed" }));
      }
    } catch {
      console.error(JSON.stringify({ level: "error", event: "artifact_creation_cleanup_failed" }));
    }
  }
}

function artifactVersionStorageKey(id: string, extension: string): string {
  return `artifacts/${id}/${Date.now()}.${extension}`;
}

function uuidV7(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  let timestamp = BigInt(Date.now());
  for (let index = 5; index >= 0; index -= 1) {
    bytes[index] = Number(timestamp & 0xffn);
    timestamp >>= 8n;
  }
  bytes[6] = (bytes[6]! & 0x0f) | 0x70;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const value = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}

function parseUpload(request: Request, maximum: number): ArtifactUpload {
  const contentLength = parseContentLength(request, maximum);
  const contentEncoding = request.headers.get("content-encoding")?.toLowerCase();
  if (contentEncoding && contentEncoding !== "identity") {
    throw new ArtifactRequestError(415, "unsupported_content_encoding");
  }
  const contentType = request.headers.get("content-type") || "application/octet-stream";
  if (contentType.length > 255) throw new ArtifactRequestError(400, "invalid_content_type");
  return { contentLength, contentType, extension: artifactFileExtension(request, contentType) };
}

function artifactFileExtension(request: Request, contentType: string): string {
  const disposition = request.headers.get("content-disposition");
  const filename = disposition && disposition.length <= 1024
    ? /(?:^|;)\s*filename="[^"]*\.([a-z0-9]{1,16})"\s*(?:;|$)/i.exec(disposition)?.[1]
    : undefined;
  if (filename) return filename.toLowerCase();
  const mediaType = contentType.split(";", 1)[0]!.trim().toLowerCase();
  if (mediaType === "text/html") return "html";
  return mediaType.startsWith("text/") ? "txt" : "bin";
}

function parseContentLength(request: Request, maximum: number): number {
  const value = request.headers.get("content-length");
  if (!value) throw new ArtifactRequestError(411, "content_length_required");
  if (!/^\d+$/.test(value)) throw new ArtifactRequestError(400, "invalid_content_length");
  const length = Number(value);
  if (!Number.isSafeInteger(length)) throw new ArtifactRequestError(400, "invalid_content_length");
  if (length > maximum) throw new ArtifactRequestError(413, "artifact_too_large");
  return length;
}

export function artifactResponse(record: ArtifactRecord): Record<string, string> {
  return {
    id: record.id,
    visibility: record.visibility,
    contentType: record.contentType,
    createdAt: record.createdAt.toISOString(),
    updatedAt: record.updatedAt.toISOString(),
  };
}

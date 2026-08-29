import { z } from "zod";

import type { Identity } from "../auth/identity";
import type { ArtifactRecord, AuthStore } from "../auth/store";
import { DEFAULT_ARTIFACT_MAX_BYTES, type AppConfig } from "../config";
import { ArtifactStorageError, artifactStorageKey, type ArtifactReadMethod, type ArtifactStorage } from "./storage";

const artifactIdSchema = z.uuid();
const visibilitySchema = z.object({ visibility: z.enum(["private", "public"]) }).strict();

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
      "getArtifact" | "createArtifact" | "touchArtifact" | "updateArtifactVisibility" | "deleteArtifact"
    >,
    private readonly storage?: ArtifactStorage,
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

  async put(id: string, identity: Identity, request: Request): Promise<{ artifact: ArtifactRecord; created: boolean }> {
    const storage = this.requireStorage();
    const contentLength = parseContentLength(request, this.config.artifactMaxBytes ?? DEFAULT_ARTIFACT_MAX_BYTES);
    const contentEncoding = request.headers.get("content-encoding")?.toLowerCase();
    if (contentEncoding && contentEncoding !== "identity") {
      throw new ArtifactRequestError(415, "unsupported_content_encoding");
    }
    const contentType = request.headers.get("content-type") || "application/octet-stream";
    if (contentType.length > 255) throw new ArtifactRequestError(400, "invalid_content_type");

    let artifact = await this.get(id);
    let created = false;
    if (!artifact) {
      created = await this.metadata(() => this.store.createArtifact({
        id,
        ownerWorkspaceId: identity.workspaceId,
        contentType,
      }));
      artifact = await this.get(id);
    }
    if (!artifact || artifact.ownerWorkspaceId !== identity.workspaceId) {
      throw new ArtifactRequestError(404, "artifact_not_found");
    }
    if (artifact.contentType !== contentType) {
      throw new ArtifactRequestError(409, "artifact_content_type_mismatch");
    }
    const body = request.body ?? new Uint8Array();
    await this.storageCall(() => storage.put(
      artifactStorageKey(id),
      body,
      contentLength,
      contentType,
      request.signal,
    ));
    const updated = await this.metadata(() => this.store.touchArtifact(id, identity.workspaceId));
    if (!updated) {
      await this.storageCall(() => storage.delete(artifactStorageKey(id)));
      throw new ArtifactRequestError(404, "artifact_not_found");
    }
    return { artifact: updated, created };
  }

  async read(
    artifact: ArtifactRecord,
    method: ArtifactReadMethod,
    request: Request,
  ): Promise<Response> {
    const storage = this.requireStorage();
    return this.storageCall(() => storage.read(
      artifactStorageKey(artifact.id),
      method,
      request,
      artifact.contentType,
    ));
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
      const exists = await this.storageCall(() => this.requireStorage().exists(artifactStorageKey(id), signal));
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

  async delete(id: string, identity: Identity, signal?: AbortSignal): Promise<void> {
    await this.getOwned(id, identity);
    await this.storageCall(() => this.requireStorage().delete(artifactStorageKey(id), signal));
    const deleted = await this.metadata(() => this.store.deleteArtifact(id, identity.workspaceId));
    if (!deleted) throw new ArtifactRequestError(404, "artifact_not_found");
  }

  async getOwned(id: string, identity: Identity): Promise<ArtifactRecord> {
    const artifact = await this.get(id);
    if (!artifact || artifact.ownerWorkspaceId !== identity.workspaceId) {
      throw new ArtifactRequestError(404, "artifact_not_found");
    }
    return artifact;
  }

  private requireStorage(): ArtifactStorage {
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
      const code = error instanceof ArtifactStorageError ? error.code : "artifact_storage_unavailable";
      throw new ArtifactRequestError(502, code);
    }
  }
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

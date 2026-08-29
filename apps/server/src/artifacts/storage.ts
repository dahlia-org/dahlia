export type ArtifactReadMethod = "GET" | "HEAD";

export class ArtifactStorageError extends Error {
  constructor(readonly code = "artifact_storage_unavailable") {
    super(code);
  }
}

export interface ArtifactStorage {
  put(
    key: string,
    body: ReadableStream<Uint8Array> | Uint8Array,
    contentLength: number,
    contentType: string,
    signal?: AbortSignal,
  ): Promise<void>;
  exists(key: string, signal?: AbortSignal): Promise<boolean>;
  read(key: string, method: ArtifactReadMethod, request: Request, contentType: string): Promise<Response>;
  delete(key: string, signal?: AbortSignal): Promise<void>;
}

export function artifactStorageKey(id: string): string {
  return `artifacts/${id}`;
}

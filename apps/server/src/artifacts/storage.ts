export type ArtifactReadMethod = "GET" | "HEAD";

export class ObjectStorageError extends Error {
  constructor(readonly code = "artifact_storage_unavailable") {
    super(code);
  }
}

export interface ObjectStorage {
  put(
    key: string,
    body: ReadableStream<Uint8Array> | Uint8Array,
    contentLength: number,
    contentType: string,
    signal?: AbortSignal,
  ): Promise<void>;
  exists(key: string, signal?: AbortSignal): Promise<boolean>;
  read(key: string, method: ArtifactReadMethod, request: Request): Promise<Response>;
  delete(key: string, signal?: AbortSignal): Promise<void>;
}

export function parseByteRange(
  value: string | null,
  size: number,
): { start: number; end: number } | undefined | null {
  if (!value) return undefined;
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!match || size === 0) return null;
  const [, first, last] = match;
  if (!first && !last) return null;
  if (!first) {
    const suffix = Number(last);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
    return { start: Math.max(0, size - suffix), end: size - 1 };
  }
  const start = Number(first);
  const requestedEnd = last ? Number(last) : size - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(requestedEnd) || start > requestedEnd || start >= size) {
    return null;
  }
  return { start, end: Math.min(requestedEnd, size - 1) };
}

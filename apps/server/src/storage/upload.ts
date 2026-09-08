export interface ParsedUpload {
  contentLength: number;
  contentType: string;
}

export class RequestError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
  }
}

export function parseUpload(request: Request, maximum: number): ParsedUpload {
  const contentLength = parseContentLength(request, maximum);
  const contentEncoding = request.headers.get("content-encoding")?.toLowerCase();
  if (contentEncoding && contentEncoding !== "identity") {
    throw new RequestError(415, "unsupported_content_encoding");
  }
  const contentType = request.headers.get("content-type") || "application/octet-stream";
  if (contentType.length > 255) throw new RequestError(400, "invalid_content_type");
  return { contentLength, contentType };
}

export function parseContentLength(request: Request, maximum: number): number {
  const value = request.headers.get("content-length");
  if (!value) throw new RequestError(411, "content_length_required");
  if (!/^\d+$/.test(value)) throw new RequestError(400, "invalid_content_length");
  const length = Number(value);
  if (!Number.isSafeInteger(length)) throw new RequestError(400, "invalid_content_length");
  if (length > maximum) throw new RequestError(413, "request_too_large");
  return length;
}

export function boundedUploadBody(body: ReadableStream<Uint8Array> | null, size: number, errorCode: string,
  validateChunk?: (chunk: Uint8Array) => void): ReadableStream<Uint8Array> | null {
  if (!body && size !== 0) throw new RequestError(400, errorCode);
  let received = 0;
  return body?.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      received += chunk.byteLength;
      if (received > size) throw new RequestError(413, errorCode);
      validateChunk?.(chunk);
      controller.enqueue(chunk);
    },
    flush() {
      if (received !== size) throw new RequestError(400, errorCode);
    },
  })) ?? null;
}

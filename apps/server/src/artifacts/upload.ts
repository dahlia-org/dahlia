export interface ParsedUpload {
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

export function parseUpload(request: Request, maximum: number): ParsedUpload {
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

export function parseContentLength(request: Request, maximum: number): number {
  const value = request.headers.get("content-length");
  if (!value) throw new ArtifactRequestError(411, "content_length_required");
  if (!/^\d+$/.test(value)) throw new ArtifactRequestError(400, "invalid_content_length");
  const length = Number(value);
  if (!Number.isSafeInteger(length)) throw new ArtifactRequestError(400, "invalid_content_length");
  if (length > maximum) throw new ArtifactRequestError(413, "artifact_too_large");
  return length;
}

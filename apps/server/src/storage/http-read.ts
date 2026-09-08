import type { StorageReadMethod } from "./storage";

const conditions = ["if-match", "if-unmodified-since", "if-none-match", "if-modified-since", "if-range"];

// Evaluate the public representation's validators, never the storage provider's ETag.
export async function conditionalRead(request: Request, method: StorageReadMethod, headers: Headers,
  read: (method: StorageReadMethod, request: Request) => Promise<Response>): Promise<Response> {
  const etag = headers.get("etag")!;
  const input = request.headers;
  const tagsMatch = (value: string, weak: boolean) => {
    if (value.trim() === "*") return true;
    const tags = value.match(/(?:W\/)?"[^"\r\n]*"/g) ?? [];
    return tags.some((tag) => {
      if (weak) return tag.replace(/^W\//, "") === etag.replace(/^W\//, "");
      return !tag.startsWith("W/") && !etag.startsWith("W/") && tag === etag;
    });
  };
  const storageRequest = new Request(request, { method });
  for (const name of conditions) storageRequest.headers.delete(name);
  if (method === "HEAD" || !/^bytes=/.test(input.get("range") ?? "")) storageRequest.headers.delete("range");
  const result = (status: number) => {
    if (status >= 400) headers.set("cache-control", "no-store");
    return new Response(null, { status, headers });
  };
  const finish = (response: Response) => {
    for (const name of ["accept-ranges", "content-length", "content-range", "last-modified"]) {
      const value = response.headers.get(name);
      if (value) headers.set(name, value);
    }
    if (!response.ok) headers.set("cache-control", "no-store");
    return new Response(method === "HEAD" ? null : response.body, { status: response.status, headers });
  };
  let metadata: Response | undefined;
  const modifiedAt = async () => {
    if (!metadata) {
      const head = new Request(storageRequest, { method: "HEAD" });
      head.headers.delete("range");
      metadata = await read("HEAD", head);
    }
    const value = metadata.headers.get("last-modified");
    if (value) headers.set("last-modified", value);
    return value ? Date.parse(value) : NaN;
  };
  const ifMatch = input.get("if-match");
  if (ifMatch !== null && !tagsMatch(ifMatch, false)) return result(412);
  const unmodified = Date.parse(input.get("if-unmodified-since") ?? "");
  if (ifMatch === null && Number.isFinite(unmodified)) {
    const modified = await modifiedAt();
    if (!metadata!.ok) return finish(metadata!);
    if (modified > unmodified) return result(412);
  }
  const ifNoneMatch = input.get("if-none-match");
  if (ifNoneMatch !== null) {
    if (tagsMatch(ifNoneMatch, true)) return result(304);
  } else {
    const since = Date.parse(input.get("if-modified-since") ?? "");
    if (Number.isFinite(since)) {
      const modified = await modifiedAt();
      if (!metadata!.ok) return finish(metadata!);
      if (modified <= since) return result(304);
    }
  }
  const ifRange = input.get("if-range")?.trim() ?? null;
  if (storageRequest.headers.has("range") && ifRange !== null) {
    let matches = !ifRange.startsWith("W/") && !etag.startsWith("W/") && ifRange === etag;
    if (!ifRange.startsWith('"') && !ifRange.startsWith("W/")) {
      const modified = await modifiedAt();
      if (!metadata!.ok) return finish(metadata!);
      // A date is usable as a strong validator only outside the 60-second ambiguity window.
      matches = modified === Date.parse(ifRange) && modified <= Date.now() - 60_000;
    }
    if (!matches) storageRequest.headers.delete("range");
  }
  return finish(method === "HEAD" && metadata ? metadata : await read(method, storageRequest));
}

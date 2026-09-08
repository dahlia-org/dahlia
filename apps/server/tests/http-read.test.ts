import { describe, expect, it, vi } from "vitest";
import { conditionalRead } from "../src/storage/http-read";
import { parseByteRange, type StorageReadMethod } from "../src/storage/storage";

const modified = "Tue, 01 Sep 2026 00:00:00 GMT";
const old = "Mon, 31 Aug 2026 00:00:00 GMT";
const etag = '"public,checksum"';

function request(headers: Record<string, string>, method: StorageReadMethod = "GET") {
  const read = vi.fn(async (method: StorageReadMethod, request: Request) => {
    for (const name of ["if-match", "if-none-match", "if-modified-since", "if-unmodified-since", "if-range"]) {
      expect(request.headers.has(name)).toBe(false);
    }
    const range = parseByteRange(request.headers.get("range"), 5);
    const headers = new Headers({ "last-modified": modified, etag: '"provider-etag"', "accept-ranges": "bytes" });
    if (range === null) return new Response(null, { status: 416, headers });
    headers.set("content-length", String(range ? range.end - range.start + 1 : 5));
    if (range) headers.set("content-range", `bytes ${range.start}-${range.end}/5`);
    return new Response(method === "HEAD" ? null : "hello".slice(range?.start, range ? range.end + 1 : undefined),
      { status: range ? 206 : 200, headers });
  });
  return { read, response: conditionalRead(new Request("https://dahlia.invalid/file", { headers, method }), method,
    new Headers({ etag, "content-type": "text/plain", "cache-control": "private, no-cache" }), read) };
}

describe("public representation HTTP preconditions", () => {
  it.each([
    [{ "if-match": '"wrong"' }, 412],
    [{ "if-match": `W/${etag}` }, 412],
    [{ "if-match": `"other", ${etag}` }, 200],
    [{ "if-match": "*", "if-unmodified-since": old }, 200],
    [{ "if-match": '"wrong"', "if-none-match": etag }, 412],
    [{ "if-unmodified-since": old, "if-none-match": etag }, 412],
    [{ "if-unmodified-since": modified, "if-none-match": etag }, 304],
    [{ "if-none-match": `W/${etag}, "other"` }, 304],
    [{ "if-none-match": "*", range: "bytes=999-" }, 304],
    [{ "if-none-match": '"wrong"', "if-modified-since": modified }, 200],
    [{ "if-modified-since": modified }, 304],
    [{ "if-modified-since": old }, 200],
    [{ "if-modified-since": "invalid" }, 200],
    [{ "if-unmodified-since": "invalid" }, 200],
    [{ range: "bytes=1-3", "if-range": etag }, 206],
    [{ range: "bytes=1-3", "if-range": '"provider-etag"' }, 200],
    [{ range: "bytes=1-3", "if-range": `W/${etag}` }, 200],
    [{ range: "bytes=1-3", "if-range": modified }, 206],
    [{ range: "bytes=999-", "if-range": old }, 200],
    [{ range: "bytes=999-", "if-range": "invalid" }, 200],
    [{ range: "bytes=999-" }, 416],
    [{ range: "items=1-3" }, 200],
  ] as Array<[Record<string, string>, number]>)("evaluates %j as %i", async (headers, status) => {
    const response = await request(headers).response;
    expect(response.status).toBe(status);
    expect(response.headers.get("etag")).toBe(etag);
    const body = await response.text();
    expect(body).toBe(status === 200 ? "hello" : status === 206 ? "ell" : "");
    if (status === 304 || status === 412) expect(response.headers.has("content-length")).toBe(false);
  });

  it.each(["bytes=1-3", "bytes=999-"])("ignores HEAD Range %s", async (range) => {
    const response = await request({ range }, "HEAD").response;
    expect(response.status).toBe(200);
    expect(response.headers.get("content-length")).toBe("5");
    expect(response.headers.has("content-range")).toBe(false);
    expect(await response.text()).toBe("");
  });

  it("does not access storage for ETag revalidation", async () => {
    const { read, response } = request({ "if-none-match": etag });
    expect((await response).status).toBe(304);
    expect(read).not.toHaveBeenCalled();
  });

  it("does not turn a failed date metadata read into a successful cache response", async () => {
    const response = await conditionalRead(new Request("https://dahlia.invalid/file", {
      headers: { "if-unmodified-since": modified, "if-none-match": etag },
    }), "GET", new Headers({ etag }), async () => new Response(null, { status: 404 }));
    expect(response.status).toBe(404);
    expect(response.headers.get("cache-control")).toBe("no-store");
  });
});

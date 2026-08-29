import { ObjectStorageError, parseByteRange, type ArtifactReadMethod, type ObjectStorage } from "./storage";

interface R2ObjectLike {
  body?: ReadableStream;
  httpEtag: string;
  range?: { offset: number; length: number };
  size: number;
  uploaded: Date;
}

export interface R2BucketLike {
  put(
    key: string,
    value: ReadableStream<Uint8Array> | Uint8Array,
    options: { httpMetadata: { cacheControl: string; contentType: string } },
  ): Promise<unknown>;
  head(key: string): Promise<R2ObjectLike | null>;
  get(key: string, options?: { onlyIf?: Headers; range?: Headers }): Promise<R2ObjectLike | null>;
  delete(key: string): Promise<void>;
}

export class R2ObjectStorage implements ObjectStorage {
  constructor(private readonly bucket: R2BucketLike) {}

  async put(
    key: string,
    body: ReadableStream<Uint8Array> | Uint8Array,
    _contentLength: number,
    contentType: string,
  ): Promise<void> {
    try {
      await this.bucket.put(key, body, {
        httpMetadata: { cacheControl: "private, no-store", contentType },
      });
    } catch {
      throw new ObjectStorageError();
    }
  }

  async exists(key: string): Promise<boolean> {
    try {
      return await this.bucket.head(key) !== null;
    } catch {
      throw new ObjectStorageError();
    }
  }

  async read(key: string, method: ArtifactReadMethod, request: Request): Promise<Response> {
    try {
      if (method === "HEAD") {
        const object = await this.bucket.head(key);
        if (!object) return new Response(null, { status: 404 });
        const since = request.headers.get("if-unmodified-since");
        if (since && object.uploaded.getTime() >= Date.parse(since) + 1000) {
          return new Response(null, { status: 412 });
        }
        const range = parseByteRange(request.headers.get("range"), object.size);
        if (range === null) {
          return new Response(null, { status: 416, headers: { "content-range": `bytes */${object.size}` } });
        }
        return objectResponse(
          range ? { ...object, range: { offset: range.start, length: range.end - range.start + 1 } } : object,
          null,
          range ? 206 : 200,
        );
      }
      const options = new Headers();
      for (const name of ["range", "if-unmodified-since"]) {
        const value = request.headers.get(name);
        if (value) options.set(name, value);
      }
      const rangeHeader = request.headers.get("range");
      if (rangeHeader) {
        const metadata = await this.bucket.head(key);
        if (!metadata) return new Response(null, { status: 404 });
        const range = parseByteRange(rangeHeader, metadata.size);
        if (range === null) {
          return new Response(null, { status: 416, headers: { "content-range": `bytes */${metadata.size}` } });
        }
      }
      const object = await this.bucket.get(key, { onlyIf: options, range: options });
      if (!object) return new Response(null, { status: 404 });
      if (!object.body) return new Response(null, { status: 412 });
      return objectResponse(object, object.body, object.range ? 206 : 200);
    } catch {
      throw new ObjectStorageError();
    }
  }

  async delete(key: string): Promise<void> {
    try {
      await this.bucket.delete(key);
    } catch {
      throw new ObjectStorageError();
    }
  }
}

function objectResponse(object: R2ObjectLike, body: ReadableStream | null, status: number): Response {
  const headers = new Headers({
    "accept-ranges": "bytes",
    etag: object.httpEtag,
    "last-modified": object.uploaded.toUTCString(),
  });
  if (object.range) {
    const end = object.range.offset + object.range.length - 1;
    headers.set("content-length", String(object.range.length));
    headers.set("content-range", `bytes ${object.range.offset}-${end}/${object.size}`);
  } else {
    headers.set("content-length", String(object.size));
  }
  return new Response(body, { status, headers });
}

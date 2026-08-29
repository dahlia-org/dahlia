import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, rename, stat, unlink, writeFile } from "node:fs/promises";
import { dirname, resolve, sep } from "node:path";
import { randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

import { ObjectStorageError, parseByteRange, type ArtifactReadMethod, type ObjectStorage } from "./storage";

export class LocalObjectStorage implements ObjectStorage {
  private readonly root: string;

  constructor(root: string) {
    this.root = resolve(root);
  }

  async put(
    key: string,
    body: ReadableStream<Uint8Array> | Uint8Array,
    contentLength: number,
    _contentType: string,
    signal?: AbortSignal,
  ): Promise<void> {
    const path = this.path(key);
    const temporary = `${path}.${randomUUID()}.tmp`;
    try {
      await mkdir(dirname(path), { recursive: true });
      if (body instanceof Uint8Array) {
        await writeFile(temporary, body, { flag: "wx", signal });
      } else {
        await pipeline(
          Readable.fromWeb(body as import("node:stream/web").ReadableStream),
          createWriteStream(temporary, { flags: "wx" }),
          { signal },
        );
      }
      if ((await stat(temporary)).size !== contentLength) throw new ObjectStorageError();
      await rename(temporary, path);
    } catch (error) {
      if (error instanceof ObjectStorageError) throw error;
      throw new ObjectStorageError();
    } finally {
      await unlink(temporary).catch(() => undefined);
    }
  }

  async exists(key: string): Promise<boolean> {
    try {
      return (await stat(this.path(key))).isFile();
    } catch (error) {
      if (isMissing(error)) return false;
      throw new ObjectStorageError();
    }
  }

  async read(key: string, method: ArtifactReadMethod, request: Request): Promise<Response> {
    let info;
    const path = this.path(key);
    try {
      info = await stat(path);
    } catch (error) {
      if (isMissing(error)) return new Response(null, { status: 404 });
      throw new ObjectStorageError();
    }
    const headers = new Headers({
      "accept-ranges": "bytes",
      "last-modified": info.mtime.toUTCString(),
    });
    const since = request.headers.get("if-unmodified-since");
    if (since && info.mtimeMs >= Date.parse(since) + 1000) return new Response(null, { status: 412, headers });
    const range = parseByteRange(request.headers.get("range"), info.size);
    if (range === null) {
      headers.set("content-range", `bytes */${info.size}`);
      return new Response(null, { status: 416, headers });
    }
    const start = range?.start ?? 0;
    const end = range?.end ?? Math.max(0, info.size - 1);
    const length = info.size === 0 ? 0 : end - start + 1;
    headers.set("content-length", String(length));
    if (range) headers.set("content-range", `bytes ${start}-${end}/${info.size}`);
    const body = method === "HEAD" || info.size === 0
      ? null
      : Readable.toWeb(createReadStream(path, { start, end, signal: request.signal })) as ReadableStream;
    return new Response(body, { status: range ? 206 : 200, headers });
  }

  async delete(key: string): Promise<void> {
    try {
      await unlink(this.path(key));
    } catch (error) {
      if (!isMissing(error)) throw new ObjectStorageError();
    }
  }

  private path(key: string): string {
    const path = resolve(this.root, key);
    if (!path.startsWith(`${this.root}${sep}`)) throw new ObjectStorageError();
    return path;
  }
}

function isMissing(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === "ENOENT";
}

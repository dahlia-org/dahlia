import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { DatabricksVolumeObjectStorage } from "../src/artifacts/databricks-volume";
import { LocalObjectStorage } from "../src/artifacts/local";
import { R2ObjectStorage, type R2BucketLike } from "../src/artifacts/r2";
import { S3ObjectStorage } from "../src/artifacts/s3";
import type { ObjectStorage } from "../src/artifacts/storage";

const KEY = "artifacts/019cc4dd-e5c5-7bd4-94e0-98df9cc40db9";
const UPLOADED = new Date("2026-08-28T00:00:00Z");

describe("R2 object storage", () => {
  it("stores and relays bytes through the binding without a signed redirect", async () => {
    let stored: { key: string; cacheControl: string; contentType: string; body: string } | undefined;
    const bucket: R2BucketLike = {
      put: async (key, value, options) => {
        stored = {
          key,
          cacheControl: options.httpMetadata.cacheControl,
          contentType: options.httpMetadata.contentType,
          body: value instanceof Uint8Array ? new TextDecoder().decode(value) : await new Response(value).text(),
        };
      },
      head: async () => ({ httpEtag: '"etag"', size: 5, uploaded: UPLOADED }),
      get: async (_key, options) => ({
        body: new Response("ell").body!,
        httpEtag: '"etag"',
        range: options?.range?.has("range") ? { offset: 1, length: 3 } : undefined,
        size: 5,
        uploaded: UPLOADED,
      }),
      delete: async () => undefined,
    };
    const storage = new R2ObjectStorage(bucket);
    await storage.put(KEY, new TextEncoder().encode("hello"), 5, "text/html");
    expect(stored).toEqual({
      key: KEY,
      cacheControl: "private, no-store",
      contentType: "text/html",
      body: "hello",
    });

    const response = await storage.read(KEY, "GET", new Request("https://dahlia.example", {
      headers: { range: "bytes=1-3" },
    }));
    expect(response.status).toBe(206);
    expect(response.headers.get("location")).toBeNull();
    expect(response.headers.get("content-range")).toBe("bytes 1-3/5");
    expect(await response.text()).toBe("ell");
    const head = await storage.read(KEY, "HEAD", new Request("https://dahlia.example", {
      headers: { range: "bytes=1-3" },
    }));
    expect(head.status).toBe(206);
    expect(head.headers.get("content-range")).toBe("bytes 1-3/5");
    expect(await head.text()).toBe("");
  });
});

describe("local object storage", () => {
  it("persists replacements and serves ranges within its root", async () => {
    const root = await mkdtemp(join(tmpdir(), "dahlia-storage-"));
    try {
      const storage = new LocalObjectStorage(root);
      await storage.put(KEY, new TextEncoder().encode("hello"), 5, "text/plain");
      await storage.put(KEY, new TextEncoder().encode("world"), 5, "text/plain");
      const response = await storage.read(KEY, "GET", new Request("https://dahlia.example", {
        headers: { range: "bytes=1-3" },
      }));
      expect(response.status).toBe(206);
      expect(response.headers.get("content-range")).toBe("bytes 1-3/5");
      expect(await response.text()).toBe("orl");
      const stale = await storage.read(KEY, "GET", new Request("https://dahlia.example", {
        headers: { "if-unmodified-since": "Thu, 01 Jan 1970 00:00:00 GMT" },
      }));
      expect(stale.status).toBe(412);
      const invalid = await storage.read(KEY, "GET", new Request("https://dahlia.example", {
        headers: { range: "bytes=9-10" },
      }));
      expect(invalid.status).toBe(416);
      expect(invalid.headers.get("content-range")).toBe("bytes */5");
      await expect(storage.exists("../escape")).rejects.toThrow();
      await storage.delete(KEY);
      expect(await storage.exists(KEY)).toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});

describe("S3-compatible object storage", () => {
  it("signs origin requests and relays Range without exposing credentials", async () => {
    const calls: Request[] = [];
    const transport = vi.fn(async (input: RequestInfo | URL) => {
      const request = input as Request;
      calls.push(request);
      if (request.method === "PUT") return new Response(null, { status: 200 });
      return new Response("ell", {
        status: 206,
        headers: { "content-length": "3", "content-range": "bytes 1-3/5" },
      });
    }) as typeof fetch;
    const storage = new S3ObjectStorage({
      accessKeyId: "access-key",
      bucket: "bucket",
      endpoint: "https://s3.example",
      region: "auto",
      secretAccessKey: "never-return-this-secret",
      sessionToken: "session-token",
    }, transport);
    await storage.put(KEY, new Response("hello").body!, 5, "text/plain");
    const response = await storage.read(KEY, "GET", new Request("https://dahlia.example", {
      headers: { range: "bytes=1-3" },
    }));

    expect(calls[0]!.url).toBe(`https://s3.example/bucket/${KEY}`);
    expect(calls[0]!.headers.get("authorization")).toContain("Credential=access-key/");
    expect(calls[0]!.headers.get("x-amz-content-sha256")).toBe("UNSIGNED-PAYLOAD");
    expect(calls[1]!.headers.get("range")).toBe("bytes=1-3");
    expect(response.headers.get("location")).toBeNull();
    expect(JSON.stringify([...response.headers])).not.toContain("never-return-this-secret");
    expect(await response.text()).toBe("ell");

    const awsCalls: Request[] = [];
    const aws = new S3ObjectStorage({
      accessKeyId: "access-key",
      bucket: "bucket",
      region: "ap-northeast-1",
      secretAccessKey: "secret",
    }, vi.fn(async (input: RequestInfo | URL) => {
      awsCalls.push(input as Request);
      return new Response(null, { status: 200 });
    }));
    expect(await aws.exists(KEY)).toBe(true);
    expect(awsCalls[0]!.url).toBe(`https://bucket.s3.ap-northeast-1.amazonaws.com/${KEY}`);
  });
});

describe("Databricks Volume object storage", () => {
  it("uses OAuth, raw PUT, encoded Files API paths, and streaming", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const transport = vi.fn(async (input: RequestInfo | URL, init: RequestInit = {}) => {
      const url = String(input);
      calls.push({ url, init });
      if (url.endsWith("/oidc/v1/token")) return Response.json({ access_token: "token", expires_in: 3600 });
      if (init.method === "PUT") return new Response(null, { status: 204 });
      return new Response("partial", {
        status: 206,
        headers: { "content-range": "bytes 0-6/7", "content-length": "7" },
      });
    }) as typeof fetch;
    const storage: ObjectStorage = new DatabricksVolumeObjectStorage({
      host: "https://workspace.example",
      clientId: "client",
      clientSecret: "secret",
      tokenUrl: "https://workspace.example/oidc/v1/token",
    }, "/Volumes/main/default/assets with spaces", transport);

    await storage.put(KEY, new TextEncoder().encode("hello"), 5, "text/html");
    const request = new Request("https://dahlia.example", { headers: { range: "bytes=0-6" } });
    const response = await storage.read(KEY, "GET", request);
    expect(calls[1]!.url).toBe(
      `https://workspace.example/api/2.0/fs/files/Volumes/main/default/assets%20with%20spaces/${KEY}?overwrite=true`,
    );
    expect(new Headers(calls[1]!.init.headers).get("authorization")).toBe("Bearer token");
    expect(new Headers(calls[2]!.init.headers).get("range")).toBe("bytes=0-6");
    expect(calls[2]!.init.signal).toBe(request.signal);
    expect(response.status).toBe(206);
    expect(await response.text()).toBe("partial");
  });

  it("maps missing files and upstream failures without relaying error bodies", async () => {
    let status = 404;
    const transport = vi.fn(async (input: RequestInfo | URL) => String(input).endsWith("/oidc/v1/token")
      ? Response.json({ access_token: "token", expires_in: 3600 })
      : new Response("contains a storage path", { status })) as typeof fetch;
    const storage: ObjectStorage = new DatabricksVolumeObjectStorage({
      host: "https://workspace.example",
      clientId: "client",
      clientSecret: "secret",
      tokenUrl: "https://workspace.example/oidc/v1/token",
    }, "/Volumes/main/default/artifacts", transport);

    const missing = await storage.read(KEY, "GET", new Request("https://dahlia.example"));
    expect(missing.status).toBe(404);
    expect(await missing.text()).toBe("");
    status = 403;
    await expect(storage.read(KEY, "GET", new Request("https://dahlia.example"))).rejects.toThrow();
    status = 500;
    await expect(storage.read(KEY, "GET", new Request("https://dahlia.example"))).rejects.toThrow();
  });
});

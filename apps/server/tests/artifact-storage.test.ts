import { describe, expect, it, vi } from "vitest";

import { DatabricksVolumeArtifactStorage } from "../src/artifacts/databricks-volume";
import { R2ArtifactStorage, type R2BucketLike } from "../src/artifacts/r2";
import type { ArtifactStorage } from "../src/artifacts/storage";

const KEY = "artifacts/019cc4dd-e5c5-7bd4-94e0-98df9cc40db9";

describe("R2 artifact storage", () => {
  it("stores raw bytes and signs method-specific five minute URLs", async () => {
    let stored: { key: string; cacheControl: string; contentType: string; body: string } | undefined;
    const bucket: R2BucketLike = {
      put: async (key, value, options) => {
        stored = {
          key,
          cacheControl: options.httpMetadata.cacheControl,
          contentType: options.httpMetadata.contentType,
          body: value instanceof Uint8Array
            ? new TextDecoder().decode(value)
            : await new Response(value).text(),
        };
      },
      head: async () => ({}),
      delete: async () => undefined,
    };
    const storage = new R2ArtifactStorage(bucket, {
      accountId: "account",
      accessKeyId: "read-key",
      bucket: "artifacts",
      secretAccessKey: "never-return-this-secret",
    });
    await storage.put(KEY, new TextEncoder().encode("hello"), 5, "text/html");
    expect(stored).toEqual({
      key: KEY,
      cacheControl: "private, no-store",
      contentType: "text/html",
      body: "hello",
    });

    const signatures: string[] = [];
    for (const method of ["GET", "HEAD"] as const) {
      const response = await storage.read(KEY, method);
      const location = response.headers.get("location")!;
      const url = new URL(location);
      expect(response.status).toBe(307);
      expect(url.pathname).toBe(`/artifacts/${KEY}`);
      expect(url.searchParams.get("X-Amz-Expires")).toBe("300");
      expect(url.searchParams.get("X-Amz-Signature")).toBeTruthy();
      signatures.push(url.searchParams.get("X-Amz-Signature")!);
      expect(location).not.toContain("never-return-this-secret");
      expect(url.searchParams.get("X-Amz-Credential")).toContain("read-key");
    }
    expect(new Set(signatures).size).toBe(2);
  });
});

describe("Databricks Volume artifact storage", () => {
  it("uses OAuth, raw PUT, encoded Files API paths, and safe streamed response headers", async () => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const transport = vi.fn(async (input: RequestInfo | URL, init: RequestInit = {}) => {
      const url = String(input);
      calls.push({ url, init });
      if (url.endsWith("/oidc/v1/token")) {
        return Response.json({ access_token: "token", expires_in: 3600 });
      }
      if (init.method === "PUT") return new Response(null, { status: 204 });
      return new Response("partial", {
        status: 206,
        headers: {
          "content-range": "bytes 0-6/7",
          "content-length": "7",
          "last-modified": "Fri, 28 Aug 2026 00:00:00 GMT",
          "x-databricks-secret": "do-not-forward",
        },
      });
    }) as typeof fetch;
    const storage: ArtifactStorage = new DatabricksVolumeArtifactStorage({
      host: "https://workspace.example",
      clientId: "client",
      clientSecret: "secret",
      tokenUrl: "https://workspace.example/oidc/v1/token",
    }, "/Volumes/main/default/assets with spaces", transport);

    await storage.put(KEY, new TextEncoder().encode("hello"), 5, "text/html");
    const request = new Request("https://dahlia.example", {
      headers: { range: "bytes=0-6", "if-unmodified-since": "Fri, 28 Aug 2026 00:00:00 GMT" },
    });
    const response = await storage.read(
      KEY,
      "GET",
      request,
      "text/html",
    );

    expect(calls[1]!.url).toBe(
      `https://workspace.example/api/2.0/fs/files/Volumes/main/default/assets%20with%20spaces/${KEY}?overwrite=true`,
    );
    expect(new Headers(calls[1]!.init.headers).get("authorization")).toBe("Bearer token");
    expect(calls[2]!.url).not.toContain("overwrite=true");
    expect(new Headers(calls[2]!.init.headers).get("range")).toBe("bytes=0-6");
    expect(calls[2]!.init.signal).toBe(request.signal);
    expect(response.status).toBe(206);
    expect(response.headers.get("content-type")).toBe("text/html");
    expect(response.headers.get("content-security-policy")).toBe("sandbox allow-scripts");
    expect(response.headers.get("content-range")).toBe("bytes 0-6/7");
    expect(response.headers.get("x-databricks-secret")).toBeNull();
    expect(await response.text()).toBe("partial");
  });

  it("maps missing files and upstream failures without relaying error bodies", async () => {
    let status = 404;
    const transport = vi.fn(async (input: RequestInfo | URL) => String(input).endsWith("/oidc/v1/token")
      ? Response.json({ access_token: "token", expires_in: 3600 })
      : new Response("contains a storage path", { status })) as typeof fetch;
    const storage: ArtifactStorage = new DatabricksVolumeArtifactStorage({
      host: "https://workspace.example",
      clientId: "client",
      clientSecret: "secret",
      tokenUrl: "https://workspace.example/oidc/v1/token",
    }, "/Volumes/main/default/artifacts", transport);

    const missing = await storage.read(KEY, "GET", new Request("https://dahlia.example"), "text/plain");
    expect(missing.status).toBe(404);
    expect(await missing.text()).toBe("");
    status = 403;
    await expect(storage.read(KEY, "GET", new Request("https://dahlia.example"), "text/plain")).rejects.toThrow();
    status = 500;
    await expect(storage.read(KEY, "GET", new Request("https://dahlia.example"), "text/plain")).rejects.toThrow();
  });
});

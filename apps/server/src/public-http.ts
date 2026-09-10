import type { Env, Hono } from "hono";
import { publicRoute, wireValue, wireURL } from "./public-wire";
import { problemResponse } from "./api/problem";

const publicRequests = new WeakMap<Request, Request>();

/** Authentication proofs bind the external URL, before route IDs are decoded. */
export function originalPublicRequest(request: Request): Request {
  return publicRequests.get(request) ?? request;
}

/** Transport adapter shared by Node and Workers. Internal routes and services use UUIDs. */
export function installPublicIDs<E extends Env>(app: Hono<E>): void {
  const dispatch = app.fetch;
  app.fetch = async (request, env, executionCtx) => {
    const url = new URL(request.url);
    const route = publicRoute(url.pathname, request.method);
    if (!route) return dispatch(request, env, executionCtx);
    const failure = (status: number, code: string) => url.pathname.startsWith("/api/v1/")
      ? problemResponse(status, code) : Response.json({ error: code }, { status });
    let responseShape = route.response === "textSearch" && url.searchParams.get("kind") === "screenshot" ? "textScreenshotSearch" : route.response;
    let internal: Request;
    try {
      const headers = new Headers(request.headers);
      for (const [name, shape] of Object.entries(route.headers ?? {})) {
        const value = headers.get(name);
        if (value !== null) headers.set(name, String(wireValue(value, shape, "decode")));
      }
      let body: BodyInit | null = request.body;
      if (route.request && body !== null) {
        const maximum = route.limit!;
        if (Number(headers.get("content-length")) > maximum) return failure(413, "request_too_large");
        const reader = request.body!.getReader();
        const chunks: Uint8Array[] = [];
        let length = 0;
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          length += value.byteLength;
          if (length > maximum) {
            await reader.cancel();
            return failure(413, "request_too_large");
          }
          chunks.push(value);
        }
        const bytes = new Uint8Array(length);
        let offset = 0;
        for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
        const value = wireValue(JSON.parse(new TextDecoder().decode(bytes)), route.request, "decode");
        if (route.response === "textSearch" && typeof value === "object" && value !== null && "kind" in value && value.kind === "screenshot") {
          responseShape = "textScreenshotSearch";
        }
        body = JSON.stringify(value);
        if (route.request === "chunk") {
          const claimed = headers.get("x-dahlia-content-sha256") ?? "";
          const publicDigest = await crypto.subtle.digest("SHA-256", bytes);
          const actual = [...new Uint8Array(publicDigest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
          if (claimed.toLowerCase() !== actual) return failure(409, "transcript_chunk_hash_mismatch");
          headers.set("x-dahlia-public-content-sha256", actual);
          const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body));
          headers.set("x-dahlia-content-sha256", [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join(""));
        }
        headers.delete("content-length");
      }
      internal = new Request(wireURL(request.url, "decode", request.method), {
        method: request.method, headers, body,
        signal: request.signal, redirect: request.redirect,
        ...(body instanceof ReadableStream ? { duplex: "half" } : {}),
      });
    } catch {
      return failure(400, "invalid_public_id");
    }
    publicRequests.set(internal, request);
    const response = await dispatch(internal, env, executionCtx);
    const headers = new Headers(response.headers);
    const location = headers.get("location");
    if (location) headers.set("location", wireURL(location, "encode"));
    const init = { status: response.status, statusText: response.statusText, headers };
    const shape = response.ok ? responseShape : "error";
    if (request.method === "HEAD" || !shape || !headers.get("content-type")?.includes("json")) {
      return location ? new Response(response.body, init) : response;
    }
    try {
      const body = await response.text();
      if (!body) return new Response(null, init);
      const value = wireValue(JSON.parse(body), shape, "encode");
      headers.delete("content-length");
      return new Response(JSON.stringify(value), init);
    } catch {
      return failure(500, "invalid_public_response");
    }
  };
}

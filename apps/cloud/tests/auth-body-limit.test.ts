import { Hono } from "hono";
import { describe, expect, it } from "vitest";

import { AUTH_MAX_REQUEST_BYTES, authBodyLimit } from "../src/app";

function limitedAuthApp() {
  const app = new Hono();
  app.use("/api/auth/*", authBodyLimit);
  app.post("/api/auth/sign-in/social", async (context) => context.json(await context.req.json()));
  return app;
}

describe("Better Auth request limit", () => {
  it("rejects an oversized declared content length before parsing", async () => {
    const response = await limitedAuthApp().request("/api/auth/sign-in/social", {
      method: "POST",
      headers: { "content-length": String(AUTH_MAX_REQUEST_BYTES + 1) },
      body: "{}",
    });

    expect(response.status).toBe(413);
    await expect(response.json()).resolves.toEqual({ error: "request_too_large" });
  });

  it("stops an oversized chunked body before the auth handler", async () => {
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(AUTH_MAX_REQUEST_BYTES));
        controller.enqueue(new Uint8Array(1));
        controller.close();
      },
    });
    const init: RequestInit & { duplex: "half" } = {
      method: "POST",
      headers: { "transfer-encoding": "chunked" },
      body,
      duplex: "half",
    };
    const response = await limitedAuthApp().request(new Request(
      "https://dahlia.example/api/auth/sign-in/social",
      init,
    ));

    expect(response.status).toBe(413);
  });
});

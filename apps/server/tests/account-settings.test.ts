import { describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { loadConfig } from "../src/config";
import { testStore } from "./test-store";

describe("account settings API", () => {
  it("authenticates, validates partial updates and keeps initialization conditional", async () => {
    const app = createApp({ config: loadConfig({ DAHLIA_AUTH_TYPE: "header" }), authStore: testStore() });
    const headers = { "x-forwarded-email": "owner@example.com", "x-forwarded-user": "owner", "content-type": "application/json" };
    const patch = (body: unknown, extra = {}) => app.request("/api/v1/account/settings", { method: "PATCH", headers: { ...headers, ...extra }, body: JSON.stringify(body) });
    expect((await app.request("/api/v1/account/settings")).status).toBe(401);
    expect(await (await app.request("/api/v1/account/settings", { headers })).json()).toEqual({ settings: null });
    expect((await patch({ outputLanguage: "en" })).status).toBe(200);
    const result = await patch({ initialize: true, outputLanguage: "ja", analysisLanguages: { scope: "all", identifiers: [] } });
    expect(await result.json()).toMatchObject({ settings: { outputLanguage: "en" } });
    expect((await patch({ revision: 1, outputLanguage: "ja" })).status).toBe(400);
    expect((await patch({ outputLanguage: "invalid" })).status).toBe(400);
    expect((await patch({ analysisLanguages: { scope: "selected", identifiers: [] } })).status).toBe(400);
    expect((await patch({ analysisLanguages: { scope: "all" } })).status).toBe(400);
    expect((await patch({ outputLanguage: "ja" }, { origin: "https://evil.example" })).status).toBe(403);
    expect((await patch({ outputLanguage: "x".repeat(9000) })).status).toBe(413);
    const another = await app.request("/api/v1/account/settings", { headers: { ...headers, "x-forwarded-user": "other" } });
    expect(await another.json()).toEqual({ settings: null });
    expect(result.headers.get("cache-control")).toBe("no-store");
  });
});

import { describe, expect, it } from "vitest";
import { createContractApp as createApp } from "./api-test-client";
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

  it("merges nested summary fields without defaults or legacy aliases", async () => {
    const app = createApp({ config: loadConfig({ DAHLIA_AUTH_TYPE: "header" }), authStore: testStore() });
    const headers = { "x-forwarded-email": "owner@example.com", "x-forwarded-user": "owner", "content-type": "application/json" };
    const patch = (body: unknown) => app.request("/api/v1/account/settings", { method: "PATCH", headers, body: JSON.stringify(body) });
    expect(await (await app.request("/api/v1/capabilities", { headers })).json()).toEqual({});
    const processing = { location: "remote", remote: {
      workflow: "transcribeThenSummarize", summaryModel: "saved-model", reasoningEffort: "high", transcriptionModel: "gemini-3-8-flash",
    } } as const;
    const summary = { style: "detailed" };
    expect((await patch({ initialize: true, outputLanguage: "en", analysisLanguages: { scope: "all", identifiers: [] }, summary, processing })).status).toBe(200);
    const response = await patch({ summary: { style: "concise" } });
    expect(await response.json()).toEqual({ settings: {
      outputLanguage: "en", analysisLanguages: { scope: "all", identifiers: [] },
      summary: { style: "concise" }, processing,
    } });
    expect(await (await patch({ processing: { remote: { transcriptionModel: null } } })).json()).toMatchObject({
      settings: { summary: { style: "concise" }, processing: { location: "remote", remote: { summaryModel: "saved-model", reasoningEffort: "high" } } },
    });
    for (const body of [
      {}, { summary: {} }, { processing: { remote: {} } }, { processing: { remote: { detail: null } } },
      { summaryMethod: "transcript" }, { transcriptSummary: processing.remote }, { settings: { summary } },
      { summary: { style: null } }, { processing: { remote: { workflow: null } } },
      { summary: { mode: "audio" } }, { summary: { unknown: true } },
      { summary: { method: "transcript" } }, { summary: { methodSettings: {} } },
      { processing: { remote: { unknown: true } } },
      { summary: { style: "invalid" } },
      { processing: { remote: { summaryModel: "" } } },
      { processing: { remote: { transcriptionModel: "" } } },
      { processing: { remote: { reasoningEffort: "invalid" } } },
    ]) expect((await patch(body)).status).toBe(400);
    for (const location of ["local", "remote"]) {
      expect(await (await patch({ processing: { location } })).json()).toMatchObject({
        settings: { summary: { style: "concise" }, processing: { location, remote: { summaryModel: "saved-model" } } },
      });
    }
    const cleared = await (await patch({ processing: { remote: { summaryModel: null, reasoningEffort: null } } })).json();
    expect(cleared).toEqual({ settings: {
      outputLanguage: "en", analysisLanguages: { scope: "all", identifiers: [] },
      summary: { style: "concise" }, processing: { location: "remote", remote: { workflow: "transcribeThenSummarize" } },
    } });
  });
});

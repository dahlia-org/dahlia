import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config";
import { createSearchEmbedder } from "../src/search/embedding";
import { createImageCaptioner } from "../src/image-analysis/captioner";
import { DEFAULT_ACCOUNT_SETTINGS } from "../src/account-settings";
import { cloudflareModels } from "../src/ai-gateway/cloudflare";
import { isSummaryModel } from "../src/summary/audio-model";
import { createTranscriptSummaryMethod } from "../src/summary/transcript";
import { createAudioSummaryMethod } from "../src/summary/audio";
import type { MeetingSyncStore } from "../src/sync/types";
import type { MeetingSyncService } from "../src/sync/service";
import { geminiChatResponse } from "../src/summary/gemini";

const env = { DAHLIA_AUTH_SECRET: "test-better-auth-secret-at-least-32-characters", DAHLIA_AUTH_TYPE: "header", DAHLIA_AI_BACKEND: "cloudflare", OPENAI_API_KEY: "test-token",
  OPENAI_BASE_URL: "https://api.cloudflare.com/client/v4/accounts/test/ai/v1", CLOUDFLARE_AI_GATEWAY_ID: "jobs",
  DAHLIA_EMBEDDING_MODEL: "@cf/baai/bge-m3", DAHLIA_SEARCH_EMBEDDING_DIMENSIONS: "1024", DAHLIA_CAPTIONING_MODEL: "gpt-4.1" };
const config = loadConfig(env);
const native = { candidates: [{ finishReason: "STOP", content: { parts: [{ text: "secret", thought: true }, { text: "result" }] } }],
  usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 20, thoughtsTokenCount: 5, totalTokenCount: 35 } };
describe("Cloudflare background provider contracts", () => {
  it.each(["sqlite", "postgres", "hyperdrive"])("keeps provider configuration independent of %s", (database) => {
    expect(loadConfig({ ...env, DAHLIA_DATABASE_TYPE: database, DAHLIA_DATABASE_URL: database === "sqlite" ? "file:test.db" : "postgres://test@localhost/test" }).provider)
      .toMatchObject({ backend: "cloudflare", gatewayId: "jobs" });
  });
  it("rejects unsupported embedding dimensions and caption models", () => {
    expect(() => loadConfig({ ...env, DAHLIA_SEARCH_EMBEDDING_DIMENSIONS: "32" })).toThrow();
    expect(() => loadConfig({ ...env, DAHLIA_CAPTIONING_MODEL: "gemini-3-flash" })).toThrow();
  });
  it("advertises explicit text/image and audio reasoning capabilities", () => {
    const models = cloudflareModels().models;
    expect(models.find((model) => model.slug === "gpt-4.1")).toMatchObject({ input_modalities: ["text", "image"], default_reasoning_level: "none" });
    expect(models.find((model) => model.slug === "gemini-3-flash")).toMatchObject({ input_modalities: ["text", "image", "audio"], default_reasoning_level: "medium" });
  });
  it("matches selectable summary sources to provider validation", async () => {
    const catalog = cloudflareModels();
    const transcript = createTranscriptSummaryMethod(config, {} as MeetingSyncStore, {} as MeetingSyncService)!;
    const audio = createAudioSummaryMethod(config, {} as MeetingSyncStore, {} as MeetingSyncService)!;
    expect(catalog.data.filter(({ id }) => isSummaryModel(id, catalog, "transcript")).map(({ id }) => id)).toEqual(["gpt-4.1"]);
    expect(catalog.data.filter(({ id }) => isSummaryModel(id, catalog, "audio")).map(({ id }) => id)).toEqual(["gemini-3-flash"]);
    for (const { id: model } of catalog.data) {
      const settings = { model, reasoningEffort: catalog.models.find((entry) => entry.slug === model)!.default_reasoning_level as "none" | "medium", detail: "high" as const };
      for (const method of ["transcript", "audio"] as const) {
        const validation = (method === "transcript" ? transcript : audio).validateSettings!(settings);
        if (isSummaryModel(model, catalog, method)) await expect(validation).resolves.toBeUndefined();
        else await expect(validation).rejects.toThrow();
      }
      const staged = audio.validateSettings!(settings, { type: "recording", recordings: [{ micFileId: "019a0000-0000-7000-8000-000000000001", systemFileId: null }], transcriptionModel: "gemini-3-flash" });
      if (isSummaryModel(model, catalog, "transcript")) await expect(staged).resolves.toBeUndefined();
      else await expect(staged).rejects.toThrow();
    }
  });
  it("sends BGE native text input and validates 1024-dimensional results", async () => {
    const transport: typeof fetch = (url, init) => {
      expect(String(url)).toBe("https://api.cloudflare.com/client/v4/accounts/test/ai/run/@cf/baai/bge-m3");
      expect(JSON.parse(String(init?.body))).toEqual({ text: ["query"] });
      expect(init?.headers).toMatchObject({ authorization: "Bearer test-token", "cf-aig-gateway-id": "jobs", "cf-aig-collect-log": "false", "cf-aig-skip-cache": "true" });
      return Promise.resolve(Response.json({ success: true, result: { data: [Array(1024).fill(0.5)] } }));
    };
    expect(await createSearchEmbedder(config, transport)!.embedQuery("query")).toHaveLength(1024);
  });
  it("uses Responses for OCR and caption without an unsupported reasoning parameter", async () => {
    const transport: typeof fetch = (url, init) => {
      expect(String(url)).toContain("/ai/v1/responses");
      const body: unknown = JSON.parse(String(init?.body));
      expect(body).toMatchObject({ model: "openai/gpt-4.1", store: false, stream: false });
      expect(body).not.toHaveProperty("reasoning");
      return Promise.resolve(Response.json({ status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: '{"ocr_text":"hello","caption":"A slide"}' }] }] }));
    };
    expect(await createImageCaptioner(config, transport)!.analyze(new Uint8Array([1]), DEFAULT_ACCOUNT_SETTINGS)).toEqual({ ocr_text: "hello", caption: "A slide" });
  });
  it.each([429, 503, 400])("persists the existing transient/permanent distinction for HTTP %i", async (status) => {
    const transport: typeof fetch = () => Promise.resolve(new Response("private", { status }));
    await expect(createSearchEmbedder(config, transport)!.embedQuery("query")).rejects.toMatchObject({ code: `embedding_http_${status}`, retryable: status !== 400 });
    await expect(createImageCaptioner(config, transport)!.analyze(new Uint8Array(), DEFAULT_ACCOUNT_SETTINGS)).rejects.toMatchObject({ code: `captioning_http_${status}`, retryable: status !== 400 });
  });
  it("rejects oversized embeddings and malformed native vectors", async () => {
    await expect(createSearchEmbedder(config, () => Promise.resolve(new Response("x".repeat(4 * 1024 * 1024 + 1))))!.embedQuery("query"))
      .rejects.toMatchObject({ code: "embedding_response_too_large", retryable: false });
    await expect(createSearchEmbedder(config, () => Promise.resolve(Response.json({ result: { data: [[1]] } })))!.embedQuery("query"))
      .rejects.toMatchObject({ code: "embedding_dimension_mismatch" });
  });
  it("normalizes Gemini direct/enveloped output and rejects interrupted generation", () => {
    for (const body of [native, { success: true, result: native }]) {
      expect(geminiChatResponse(body)).toMatchObject({ choices: [{ message: { content: "result" } }], usage: { completion_tokens: 20, reasoning_tokens: 5 } });
    }
    expect(() => geminiChatResponse({ candidates: [{ ...native.candidates[0], finishReason: "MAX_TOKENS" }] })).toThrow();
    expect(() => geminiChatResponse({ success: false, result: native })).toThrow();
  });
});

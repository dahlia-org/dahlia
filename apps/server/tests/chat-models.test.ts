import { describe, expect, it } from "vitest";
import { chatModels, pickerModels } from "../src/agent/models";
import { createAiService } from "../src/agent/service";
import { modelList, type CodexModelWire } from "../src/ai-gateway/models";
import type { GatewayService } from "../src/ai-gateway/service";
import type { AppConfig } from "../src/config";
import policy from "../resources/codex/source.json";
import generated from "../resources/codex/models.json";
import cloudflare from "../src/ai-gateway/cloudflare-models.json";

const kimi = modelList([{ id: "system.ai.kimi-k3" }]).models.find(({ slug }) => slug === "system.ai.kimi-k3")!;
const catalog = (models: CodexModelWire[]) => ({ models, data: models.filter(({ supported_in_api }) => supported_in_api)
  .map(({ slug, display_name }) => ({ id: slug, object: "model" as const, created: 0, owned_by: "databricks", display_name })) });

describe("chat model composition", () => {
  it("adds approved GPT models to an OSS-only catalog without modifying the Gateway response", () => {
    const upstream = catalog([kimi]);
    const before = structuredClone(upstream);
    const models = chatModels(upstream, true);
    expect(models.map(({ id }) => id)).toEqual([...policy.models, kimi.slug]);
    expect(models.find(({ id }) => id === "gpt-6.1-sol")).toMatchObject({ defaultReasoningEffort: "low" });
    expect(policy.models).toEqual(["gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"]);
    expect(generated.models.map(({ slug }) => slug)).toEqual(policy.models);
    expect(models.find(({ id }) => id === "gpt-6.1-sol")?.supportedReasoningEfforts.map(({ effort }) => effort))
      .toEqual(["low", "medium", "high", "xhigh", "max", "ultra"]);
    expect(upstream).toEqual(before);
    expect(models.map(({ id }) => id)).not.toContain("codex-auto-review");
    expect(models.map(({ id }) => id)).not.toContain("gpt-daybreak-blue-latest");
  });

  it("lets upstream definitions override and hide built-ins without duplicate entries", () => {
    const override = { ...kimi, slug: "gpt-6.1-sol", display_name: "Upstream Sol",
      default_reasoning_level: "high", supported_reasoning_levels: [{ effort: "high", description: "Deep" }] };
    const merged = chatModels(catalog([override]), true);
    expect(merged.filter(({ id }) => id === override.slug)).toEqual([{ id: override.slug, displayName: "Upstream Sol",
      defaultReasoningEffort: "high", supportedReasoningEfforts: [{ effort: "high", description: "Deep" }] }]);
    for (const suppression of [{ visibility: "hide" }, { supported_in_api: false }]) {
      expect(chatModels(catalog([{ ...override, ...suppression }]), true).map(({ id }) => id)).not.toContain(override.slug);
    }
    expect(chatModels(catalog([{ ...override, default_reasoning_level: "unknown" }]), true)
      .map(({ id }) => id)).not.toContain(override.slug);
  });

  it("keeps OpenAI and Cloudflare restricted to their configured public models", () => {
    expect(chatModels(catalog([kimi])).map(({ id }) => id)).toEqual([kimi.slug]);
    expect(chatModels(catalog([]))).toEqual([]);
  });

  it.each([false, true])("preserves configured public order with bundled models %s", (includeBundled) => {
    const ids = ["gemini-3-flash", "gpt-4.1"];
    const upstream = modelList(ids.map((id) => ({ id })), cloudflare.models);
    const before = structuredClone(upstream);
    expect(chatModels(upstream, includeBundled).map(({ id }) => id))
      .toEqual([...(includeBundled ? policy.models : []), ...ids]);
    expect(upstream).toEqual(before);
  });

  it("uses the same composed definitions for Databricks chat request validation", async () => {
    const config = { baseUrl: "https://dahlia.example", provider: { backend: "databricks",
      baseUrl: "https://workspace.example/ai-gateway/codex/v1" } } as AppConfig;
    const gateway = { models: async () => catalog([kimi]) } as unknown as GatewayService;
    const service = createAiService(config, gateway, {} as never);
    expect(await service.models()).toEqual(chatModels(catalog([kimi]), true));
    const input = { workspaceId: "01990ab0-0000-7000-8000-000000000001", model: "gpt-6.1-sol",
      reasoningEffort: "none" as const, messages: [{ role: "user" as const, content: "Hello" }] };
    const rejectedEffort = service.stream(input, { userId: "user", source: "header" }, new Request(config.baseUrl));
    await expect(rejectedEffort[Symbol.asyncIterator]().next()).rejects.toMatchObject({ code: "reasoning_effort_not_supported" });
    for (const model of ["gpt-5.4", "gpt-5.5", "gpt-5.6-sol"]) {
      const rejectedModel = service.stream({ ...input, model }, { userId: "user", source: "header" }, new Request(config.baseUrl));
      await expect(rejectedModel[Symbol.asyncIterator]().next()).rejects.toMatchObject({ code: "model_not_configured" });
    }
  });

  it("does not substitute built-ins when Databricks discovery fails", async () => {
    const config = { baseUrl: "https://dahlia.example", provider: { backend: "databricks" } } as AppConfig;
    const gateway = { models: async () => { throw new Error("discovery failed"); } } as unknown as GatewayService;
    await expect(createAiService(config, gateway, {} as never).models()).rejects.toThrow("discovery failed");
  });
});

it("shares image modalities and upstream suppression with chat composition", () => {
  const upstream = catalog([kimi]);
  expect(pickerModels(upstream, true).find(({ slug }) => slug === "gpt-6-luna")?.input_modalities)
    .toEqual(["text", "image"]);
  expect(pickerModels(upstream).map(({ slug }) => slug)).not.toContain("gpt-6-luna");
  const hidden = { ...kimi, slug: "gpt-6-luna", visibility: "hide", supported_in_api: false };
  expect(pickerModels(catalog([hidden]), true).map(({ slug }) => slug)).not.toContain("gpt-6-luna");
});

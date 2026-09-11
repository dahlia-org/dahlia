import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { modelList } from "../src/ai-gateway/models";
import { cloudflareModels } from "../src/ai-gateway/cloudflare";
import catalog from "../src/ai-gateway/databricks-models.json";

// Codex main 713caa89f389acd9cbcd77016edbb607273826af, only hyphenating slugs and clearing available_in_plans.
const upstreamHashes: [string, string][] = [["gpt-6-astra","0c583692f053474cbd5b39b6f570094e4a0d407ab65f2e7cf49b5e9c50881259"],["gpt-5-6-sol","cdb22ce782efd51d35e02b9df0d4e5fbf88e304a4feaef7b4b04c78d3375f93f"],["gpt-5-6-terra","25f6bda9a542fab0ed1d76d11487c9f8d9e5ac202b68a86e918173fa1e05c95f"],["gpt-5-6-luna","1fa2793ecd8581b715c8bcd436e034cb440bf2680bc6e7572ee91a727332b4f8"],["gpt-5-5","0118f80b60c256561c482cb8cba18d7a8ac261bb878ca059076e87c3ee13ae2a"]];

const hiddenModels = modelList([]).models;

describe("model catalog", () => {
  it.each(upstreamHashes)("preserves upstream GPT metadata for %s", (slug, digest) => {
    const model = catalog.models.find((model) => model.slug === slug);
    expect(createHash("sha256").update(JSON.stringify(model)).digest("hex")).toBe(digest);
  });

  it("contains only the requested GPT families and Databricks IDs", () => {
    expect(catalog.models.filter(({ slug }) => slug.startsWith("gpt-")).map(({ slug }) => slug))
      .toEqual(upstreamHashes.map(([slug]) => slug));
    expect(catalog.models.every(({ slug }) => !slug.includes("."))).toBe(true);
    expect(new Set(catalog.models.map(({ slug }) => slug)).size).toBe(catalog.models.length);
  });

  it("returns discovered definitions unchanged, including priority and hidden Gemini", () => {
    const entries = catalog.models.map(({ slug }) => ({ id: slug, displayName: "Provider name" })).reverse();
    const list = modelList(entries);
    expect(list.models).toEqual([...catalog.models, ...hiddenModels]);
    expect(list.data.every(({ display_name }) => display_name === "Provider name")).toBe(true);
    expect(modelList([]).models).toEqual(hiddenModels);
  });

  it("does not normalize IDs or create definitions for unknown models", () => {
    const ids = ["gpt-5.6-sol", "system.ai.gpt-5-6-sol", "GPT-5-6-SOL", " gpt-5-6-sol ", "gpt-future", "glm-future", "custom"];
    const list = modelList(ids.map((id) => ({ id })));
    expect(list.models).toEqual(hiddenModels);
    expect(list.data.map(({ id, display_name }) => [id, display_name])).toEqual(ids.map((id) => [id, id]));
  });

  it("generates hidden built-ins without publishing them as available", () => {
    const list = modelList([{ id: "gpt-5-5" }]);
    expect(hiddenModels.map(({ slug }) => slug)).toEqual([
      "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-daybreak-blue-latest",
      "gpt-daybreak-red-latest", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.2",
    ]);
    expect(list.data.map(({ id }) => id)).toEqual(["gpt-5-5"]);
    for (const model of hiddenModels) {
      expect(list.models.find(({ slug }) => slug === model.slug)).toMatchObject({ visibility: "hide", supported_in_api: false });
    }
    expect(list.models.find(({ slug }) => slug === "gpt-5-5")?.visibility).toBe("list");
  });

  it("uses the JSON display name when no provider name is supplied", () => {
    const model = catalog.models[0]!;
    expect(modelList([{ id: model.slug, displayName: " \t" }]).data[0]?.display_name).toBe(model.display_name);
  });

  it.each([
    ["glm-5-3", "gpt-5-6-sol", ["text"], 1_000_000],
    ["glm-5-3-flash", "gpt-5-6-luna", ["text", "image"], 1_000_000],
    ["kimi-k3", "gpt-5-6-sol", ["text", "image"], 1_048_576],
    ["deepseek-v4-pro-0813", "gpt-5-6-sol", ["text"], 1_000_000],
    ["gemini-3-8-flash", "gpt-5-6-luna", ["text", "image", "audio"], 1_048_576],
    ["gemini-3-7-flash", "gpt-5-6-luna", ["text", "image", "audio"], 1_048_576],
  ] as const)("uses the documented capabilities and reference runtime for %s", (slug, referenceSlug, modalities, context) => {
    const model = catalog.models.find((model) => model.slug === slug)!;
    const reference = catalog.models.find((model) => model.slug === referenceSlug)!;
    expect(model).toMatchObject({ input_modalities: modalities, context_window: context, max_context_window: context });
    expect(model.shell_type).toBe(reference.shell_type);
    expect(model.truncation_policy).toEqual(reference.truncation_policy);
    expect(model.model_messages.instructions_template).toBe(reference.model_messages.instructions_template.replace("an agent based on GPT-5", "a coding agent"));
  });

  it.each(["glm-5-3", "glm-5-3-flash", "kimi-k3"])("keeps the documented thinking choices for %s", (slug) => {
    const model = catalog.models.find((model) => model.slug === slug)!;
    expect(model.default_reasoning_level).toBe("max");
    expect(model.supported_reasoning_levels.map(({ effort }) => effort)).toEqual(["low", "high", "max"]);
  });

  it("keeps non-GPT requests on the standard Responses wire format", () => {
    // Codex Lite puts tool definitions in input.additional_tools and requires an internal header.
    // Dahlia's relay implements the standard Responses contract and does not forward that header.
    for (const model of catalog.models.filter(({ slug }) => !slug.startsWith("gpt-"))) {
      expect(model.use_responses_lite, model.slug).toBe(false);
    }
  });

  it("uses DeepSeek's documented high default and optional non-thinking mode", () => {
    const model = catalog.models.find((model) => model.slug === "deepseek-v4-pro-0813")!;
    expect(model.default_reasoning_level).toBe("high");
    expect(model.supported_reasoning_levels.map(({ effort }) => effort)).toEqual(["none", "low", "high", "max"]);
  });

  it.each(["gemini-3-8-flash", "gemini-3-7-flash"])("hides %s while retaining audio summary metadata", (id) => {
    const list = modelList([{ id }]);
    expect(list.data[0]?.id).toBe(id);
    expect(list.models[0]).toMatchObject({ visibility: "hide", supported_in_api: true, default_reasoning_level: "medium", use_responses_lite: false });
    expect(list.models[0]?.supported_reasoning_levels.map(({ effort }) => effort)).toEqual(["low", "medium", "high"]);
  });

  it("keeps Cloudflare native IDs and audio summary settings independent", () => {
    const list = cloudflareModels();
    expect(list.data.map(({ id }) => id)).toEqual(["gpt-5.6-luna", "gpt-4.1", "gemini-3-flash"]);
    expect(list.models.find(({ slug }) => slug === "gemini-3-flash")).toMatchObject({ visibility: "list", summary_methods: ["audio"], use_responses_lite: false });
    expect(list.models.find(({ slug }) => slug === "gpt-4.1")).toMatchObject({ visibility: "list", summary_methods: ["transcript"] });
  });
});

import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { modelList } from "../src/ai-gateway/models";
import { cloudflareModels } from "../src/ai-gateway/cloudflare";
import catalog from "../src/ai-gateway/databricks-models.json";

// Codex main 713caa89f389acd9cbcd77016edbb607273826af, with Databricks slugs, plan availability, and space-separated display names.
const upstreamHashes: [string, string][] = [["gpt-6-astra","2398784eb6729f680770523fa868e676a342a6842433508fdeb34b87b77c112c"],["gpt-5-6-sol","8a0319235164a1db323baf7de68b862ad1becd2034972862a31b332dde1aed42"],["gpt-5-6-terra","40652a62267fb6dbcb38c24f04abb24f2880a2cf5a7c43e36fbbe4191eb351ac"],["gpt-5-6-luna","5db57f41f678e0166165febfa8760bbfa109ccd6e175acd483cf58523a63e065"],["gpt-5-5","841469379b687aa687dc5431e754d2a60baaa408b024bfe2573ab50c9f1bd55b"]];

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

  it("uses Luna runtime metadata and Pro reasoning choices for DeepSeek V4.1 Flash", () => {
    const model = catalog.models.find((model) => model.slug === "deepseek-v4-1-flash")!;
    const luna = catalog.models.find((model) => model.slug === "gpt-5-6-luna")!;
    expect(model).toMatchObject({
      input_modalities: luna.input_modalities,
      context_window: luna.context_window,
      max_context_window: luna.max_context_window,
    });
    expect(model.default_reasoning_level).toBe("high");
    expect(model.supported_reasoning_levels.map(({ effort }) => effort)).toEqual(["none", "low", "high", "max"]);
    expect(model.model_messages.instructions_template).toBe(luna.model_messages.instructions_template.replace("an agent based on GPT-5", "a coding agent"));
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

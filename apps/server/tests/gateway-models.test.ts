import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { modelList, type ModelInfo } from "../src/ai-gateway/models";
import { LATEST_CODEX_CLIENT_VERSION } from "../src/ai-gateway/service";
import catalog from "../src/ai-gateway/databricks-models.json";

describe("model display names", () => {
  it.each([
    ["gpt-6-astra", "GPT 6 Astra"],
    ["gpt-5-6-sol", "GPT 5.6 Sol"],
    ["gpt-5.6-sol", "GPT 5.6 Sol"],
    ["gpt-5-6-terra", "GPT 5.6 Terra"],
    ["gpt-5.6-terra", "GPT 5.6 Terra"],
    ["gpt-5-6-luna", "GPT 5.6 Luna"],
    ["gpt-5.6-luna", "GPT 5.6 Luna"],
    ["kimi-k3", "Kimi K3"],
    ["deepseek-v4-pro-0813", "DeepSeek V4 Pro"],
    ["glm-5-3-flash", "GLM 5.3 Flash"],
    ["glm-5-3", "GLM 5.3"],
    ["gemini-3-8-flash", "Gemini 3.8 Flash"],
    ["gemini-3-7-flash", "Gemini 3.7 Flash"],
  ])("uses the catalog display name for %s", (id, expected) => {
    expectDisplayName({ id }, expected);
  });

  it.each([
    [{ id: "gpt-5.6-sol", displayName: "Provider Sol" }, "Provider Sol"],
    [{ id: "gpt-5.6-sol", displayName: " \t\n " }, "GPT 5.6 Sol"],
    [{ id: "gpt-5.5", displayName: "" }, "GPT-5.5"],
    [{ id: "system.ai.gpt-5-6-terra", displayName: null }, "GPT 5.6 Terra"],
    [{ id: "custom-v1-0813" }, "custom-v1-0813"],
    [{ id: "deepseek-v4-pro-9999" }, "deepseek-v4-pro-9999"],
    [{ id: "constructor" }, "constructor"],
  ] satisfies [ModelInfo, string][])("resolves display-name precedence for %j", (entry, expected) => {
    expectDisplayName(entry, expected);
  });
});

describe("Codex model availability", () => {
  it("keeps the Server catalog aligned with the bundled Desktop release", () => {
    expect(LATEST_CODEX_CLIENT_VERSION).toBe("0.153.4");
    const bundle = readFileSync(new URL("../../desktop/Sources/Dahlia/Services/CodexBundle.swift", import.meta.url), "utf8");
    expect(bundle).toContain(`static let version = "${LATEST_CODEX_CLIENT_VERSION}"`);
    expect(catalog.models.find(({ slug }) => slug === "gpt-6-astra")).toBeDefined();
  });

  it("exposes Astra's six reasoning levels and low default", () => {
    const model = modelList([{ id: "gpt-6-astra" }]).models.find((model) => model.slug === "gpt-6-astra");
    expect(model).toMatchObject({ display_name: "GPT 6 Astra", default_reasoning_level: "low", visibility: "list" });
    expect(model).toMatchObject({ shell_type: "unified_exec", input_modalities: ["text", "image"], supports_reasoning_summary_parameter: true });
    expect(model).not.toHaveProperty("use_responses_lite");
    expect(model?.supported_reasoning_levels.map(({ effort }) => effort)).toEqual(["low", "medium", "high", "xhigh", "max", "ultra"]);
  });

  it("preserves provider IDs while sharing Codex runtime metadata", () => {
    const standard = modelList([{ id: "gpt-5.6-terra" }]);
    const databricks = modelList([{ id: "gpt-5-6-terra" }]);
    expect(standard.data.map(({ id }) => id)).toEqual(["gpt-5.6-terra"]);
    expect(databricks.data.map(({ id }) => id)).toEqual(["gpt-5-6-terra"]);
    const model = standard.models.find(({ slug }) => slug === "gpt-5.6-terra");
    expect(databricks.models.find(({ slug }) => slug === "gpt-5-6-terra")).toEqual({ ...model, slug: "gpt-5-6-terra" });
    expect(databricks.models.find(({ slug }) => slug === "gpt-5.6-terra")?.visibility).toBe("hide");
    for (const entry of databricks.models) {
      expect(entry).not.toHaveProperty("base_model");
      expect(entry).not.toHaveProperty("aliases");
    }
  });

  it("validates the provider catalog and keeps unavailable models hidden", () => {
    const slugs = catalog.models.map(({ slug }) => slug);
    expect(slugs).not.toContain("deepseek-v4-pro");
    expect(new Set(slugs).size).toBe(slugs.length);
    const empty = modelList([]);
    expect(empty.data).toEqual([]);
    expect(empty.models.every(({ visibility }) => visibility === "hide")).toBe(true);
  });

  it("limits GPT definitions to Astra, 5.6, and 5.5 while suppressing omitted built-ins", () => {
    expect(catalog.models.filter(({ slug }) => slug.startsWith("gpt-")).map(({ slug }) => slug).sort()).toEqual([
      "gpt-6-astra", "gpt-5.6-sol", "gpt-5-6-sol", "gpt-5.6-terra", "gpt-5-6-terra",
      "gpt-5.6-luna", "gpt-5-6-luna", "gpt-5.5", "gpt-5-5",
    ].sort());
    const list = modelList([]);
    for (const slug of ["gpt-daybreak-blue-latest", "gpt-daybreak-red-latest", "gpt-5.4", "gpt-5.4-mini", "gpt-5.2"]) {
      expect(list.models.find((model) => model.slug === slug)).toMatchObject({ visibility: "hide" });
    }
  });

  it.each([
    ["glm-5-3", "gpt-5.6-sol", ["text"]],
    ["glm-5-3-flash", "gpt-5.6-luna", ["text", "image"]],
    ["kimi-k3", "gpt-5.6-sol", ["text", "image"]],
    ["deepseek-v4-pro-0813", "gpt-5.6-sol", ["text"]],
    ["gemini-3-8-flash", "gpt-5.6-luna", ["text", "image", "audio"]],
    ["gemini-3-7-flash", "gpt-5.6-luna", ["text", "image", "audio"]],
  ] satisfies [string, string, string[]][])("expands runtime parameters and an independent description for %s", (slug, referenceSlug, inputModalities) => {
    const reference = catalog.models.find((model) => model.slug === referenceSlug)!;
    const model = modelList([{ id: slug }]).models.find((model) => model.slug === slug)!;
    expect(model).toMatchObject({
      shell_type: reference.shell_type, multi_agent_version: reference.multi_agent_version,
      apply_patch_tool_type: reference.apply_patch_tool_type, truncation_policy: reference.truncation_policy,
      context_window: reference.context_window, max_context_window: reference.max_context_window,
    });
    expect(model.description).toBeTruthy();
    expect(model.description).not.toBe(reference.description);
    expect(model.model_messages?.instructions_template).toBe(reference.model_messages.instructions_template.replace("an agent based on GPT-5", "a coding agent"));
    expect(model.input_modalities).toEqual(inputModalities);
  });

  it.each(["gemini-3-8-flash", "gemini-3-7-flash"])("defines Gemini reasoning separately for %s", (slug) => {
    const model = modelList([{ id: slug }]).models.find((model) => model.slug === slug);
    expect(model?.visibility).toBe("list");
    expect(model?.default_reasoning_level).toBe("medium");
    expect(model?.supported_reasoning_levels?.map(({ effort }) => effort)).toEqual(["low", "medium", "high"]);
  });

  it.each([
    ["gpt-5.6-sol", "GPT 5.6 Sol", "low"],
    ["gpt-5.6-terra", "GPT 5.6 Terra", "medium"],
    ["gpt-5.6-luna", "GPT 5.6 Luna", "medium"],
    ["gpt-5.5", "GPT-5.5", "medium"],
    ["gpt-future", "gpt-future", "max"],
  ])("preserves metadata for visible and hidden %s", (slug, displayName, defaultLevel) => {
    const alias = slug.replaceAll(".", "-");
    const list = modelList([{ id: alias }]);
    for (const id of new Set([slug, alias])) {
      const model = list.models.find((model) => model.slug === id);
      expect(model).toMatchObject({ display_name: displayName, default_reasoning_level: defaultLevel,
        visibility: id === alias ? "list" : "hide" });
      const efforts = model?.supported_reasoning_levels.map(({ effort }) => effort);
      expect(efforts).toContain(defaultLevel);
      if (id !== alias) expect(model?.model_messages?.instructions_template).toBe("");
    }
  });

  it("exposes catalog entries, supported fallback families, and the review alias to Codex", () => {
    const supported = ["gpt-5.6-luna", "gpt-future", "glm-5-3", "kimi-k3", "deepseek-v4-pro-0813", "gemini-3-8-flash", "gemini-3-7-flash", "codex-auto-review"];
    const excluded = ["gemini-unknown", "claude-opus", "custom", "gpt", "not-gpt-5", "system.ai.gpt-5-4-mini"];
    const list = modelList([...supported, ...excluded].map((id) => ({ id })));
    expect(list.data.map((model) => model.id)).toEqual([...supported, ...excluded]);
    expect(list.models.filter((model) => model.visibility === "list").map((model) => model.slug).sort()).toEqual([...supported].sort());
    for (const id of excluded) expect(list.models.some((model) => model.slug === id)).toBe(false);
  });

  it.each(["glm-5-3", "kimi-k3", "deepseek-v4-pro-0813"])("omits none from OSS reasoning efforts for %s", (id) => {
    const model = modelList([{ id }]).models.find((model) => model.slug === id);
    expect(model?.supported_reasoning_levels.map((level) => level.effort)).toEqual(["low", "high", "max"]);
    expect(model?.default_reasoning_level).toBe("max");
  });
});

function expectDisplayName(entry: ModelInfo, expected: string) {
  const list = modelList([entry]);
  expect(list.data).toEqual([{
    id: entry.id, object: "model", created: 0, owned_by: "dahlia", display_name: expected,
  }]);
  if (/^(gpt|glm|kimi|deepseek|gemini)-/.test(entry.id)) {
    expect(list.models.filter((model) => model.visibility === "list")).toHaveLength(1);
    expect(list.models.find((model) => model.slug === entry.id)).toMatchObject({
      slug: entry.id, display_name: expected, visibility: "list",
    });
  }
}

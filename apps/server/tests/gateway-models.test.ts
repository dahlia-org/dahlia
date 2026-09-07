import { describe, expect, it } from "vitest";
import { modelList, type ModelInfo } from "../src/ai-gateway/models";

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
    ["deepseek-v4-pro", "DeepSeek V4 Pro"],
    ["deepseek-v4-pro-0813", "DeepSeek V4 Pro"],
  ])("uses the exact dictionary name for %s", (id, expected) => {
    expectDisplayName({ id }, expected);
  });

  it.each([
    [{ id: "gpt-5.6-sol", displayName: "Provider Sol" }, "Provider Sol"],
    [{ id: "gpt-5.6-sol", displayName: " \t\n " }, "GPT 5.6 Sol"],
    [{ id: "gpt-5.4-mini", displayName: "" }, "GPT-5.4-Mini"],
    [{ id: "system.ai.gpt-5-4-mini", displayName: null }, "GPT-5.4-Mini"],
    [{ id: "custom-v1-0813" }, "custom-v1-0813"],
    [{ id: "deepseek-v4-pro-9999" }, "deepseek-v4-pro-9999"],
    [{ id: "constructor" }, "constructor"],
  ] satisfies [ModelInfo, string][])("resolves display-name precedence for %j", (entry, expected) => {
    expectDisplayName(entry, expected);
  });
});

function expectDisplayName(entry: ModelInfo, expected: string) {
  const list = modelList([entry]);
  expect(list.data).toEqual([{
    id: entry.id, object: "model", created: 0, owned_by: "dahlia", display_name: expected,
  }]);
  expect(list.models.filter((model) => model.visibility === "list")).toHaveLength(1);
  expect(list.models.find((model) => model.slug === entry.id)).toMatchObject({
    slug: entry.id, display_name: expected, visibility: "list",
  });
}

import { expect, it } from "vitest";
import { DEFAULT_WORKSPACE_GENERATION_SETTINGS, summaryStyles, summaryStyleDetail } from "../src/workspace-generation-settings";
import { modelList } from "../src/ai-gateway/models";
import { cloudflareModels } from "../src/ai-gateway/cloudflare";
import { resolveSummaryPreferences } from "../src/summary/preferences";

it("resolves automatic preferences without depending on catalog order or changing the saved choices", () => {
  const preferences = { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: { location: "remote" as const,
    remote: { workflow: "transcribeThenSummarize" as const } } };
  const before = structuredClone(preferences);
  const entries = [{ id: "gpt-5.4" }, { id: "system.ai.gemini-3-8-flash" }];
  const resolve = (reverse: boolean) => resolveSummaryPreferences(preferences, { type: "recording", recordings: [] },
    modelList(reverse ? [...entries].reverse() : entries), (id) => id);
  expect(resolve(false)).toEqual(resolve(true));
  expect(resolve(false)).toMatchObject({
    settings: { model: "system.ai.gemini-3-8-flash", detail: "high" },
    input: { transcriptionModel: "system.ai.gemini-3-8-flash" },
  });
  expect(resolve(false).settings).not.toHaveProperty("transcription");
  expect(preferences).toEqual(before);
  expect(summaryStyles.map(summaryStyleDetail)).toEqual(["low", "medium", "high", "xhigh", "max"]);
});

it("keeps inactive overrides and rejects unavailable explicit models and effort", () => {
  const preferences = structuredClone(DEFAULT_WORKSPACE_GENERATION_SETTINGS);
  preferences.processing = { location: "remote", remote: {
    workflow: "combined", summaryModel: "system.ai.gemini-3-8-flash",
  } };
  const catalog = modelList([{ id: "system.ai.gemini-3-8-flash" }]);
  const resolve = () => resolveSummaryPreferences(preferences, { type: "recording", recordings: [] }, catalog, (id) => id);
  expect(resolve().input).not.toHaveProperty("transcriptionModel");
  preferences.processing.remote.workflow = "transcribeThenSummarize";
  expect(resolve()).toMatchObject({
    settings: { model: "system.ai.gemini-3-8-flash", reasoningEffort: "medium" },
    input: { transcriptionModel: "system.ai.gemini-3-8-flash" },
  });
  preferences.processing.remote.workflow = "combined";
  preferences.processing.remote.summaryModel = "unavailable";
  expect(resolve).toThrow("summary_invalid_structured_model");
  preferences.processing.remote.summaryModel = "system.ai.gemini-3-8-flash";
  expect(resolve().settings).not.toHaveProperty("transcription");
  preferences.processing.remote.reasoningEffort = "ultra";
  expect(resolve).toThrow("summary_invalid_reasoning_effort");
});

it("uses the shared audio model and effort for retranscription", () => {
  const preferences = structuredClone(DEFAULT_WORKSPACE_GENERATION_SETTINGS);
  preferences.processing = { location: "remote", remote: {
    workflow: "combined", summaryModel: "system.ai.gemini-3-8-flash", reasoningEffort: "medium",
  } };
  const result = resolveSummaryPreferences(preferences, {
    type: "recording", recordings: [], transcriptionOnly: true,
  }, modelList([{ id: "system.ai.gemini-3-8-flash" }]), (id) => id);
  expect(result).toMatchObject({
    settings: { model: "system.ai.gemini-3-8-flash", transcriptionReasoningEffort: "medium" },
    input: { transcriptionOnly: true, transcriptionModel: "system.ai.gemini-3-8-flash" },
  });
  expect(result.settings).not.toHaveProperty("transcription");
});

it("defaults new workspaces to direct audio summary generation", () => {
  expect(DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing.remote.workflow).toBe("combined");
});

it("keeps legacy local transcript-summary preferences until a current client replaces them", () => {
  const preferences = structuredClone(DEFAULT_WORKSPACE_GENERATION_SETTINGS);
  preferences.processing = { location: "local", remote: {
    workflow: "combined", summaryModel: "gpt-4.1", reasoningEffort: "none",
  } };
  expect(resolveSummaryPreferences(preferences, { type: "transcript", version: "1" }, cloudflareModels(), (id) => id))
    .toMatchObject({ settings: { model: "gpt-4.1", reasoningEffort: "none" } });
});

it("uses separate audio and transcript-summary settings for two-stage generation", () => {
  const preferences = structuredClone(DEFAULT_WORKSPACE_GENERATION_SETTINGS);
  preferences.processing = { location: "remote", remote: {
    workflow: "transcribeThenSummarize",
    summaryModel: "gemini-3-flash", reasoningEffort: "medium",
    transcriptSummaryModel: "gpt-4.1", transcriptSummaryReasoningEffort: "none",
  } };
  expect(resolveSummaryPreferences(preferences, { type: "recording", recordings: [] }, cloudflareModels(), (id) => id))
    .toMatchObject({
      settings: { model: "gpt-4.1", reasoningEffort: "none", transcriptionReasoningEffort: "medium" },
      input: { transcriptionModel: "gemini-3-flash" },
    });
});

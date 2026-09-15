import { expect, it } from "vitest";
import { DEFAULT_WORKSPACE_GENERATION_SETTINGS, summaryStyles, summaryStyleDetail } from "../src/workspace-generation-settings";
import { modelList } from "../src/ai-gateway/models";
import { resolveSummaryPreferences } from "../src/summary/preferences";

it("resolves automatic preferences without depending on catalog order or changing the saved choices", () => {
  const preferences = { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: { location: "remote" as const,
    remote: { workflow: "transcribeThenSummarize" as const } } };
  const before = structuredClone(preferences);
  const entries = [{ id: "gpt-5.4" }, { id: "gemini-3-8-flash" }];
  const resolve = (reverse: boolean) => resolveSummaryPreferences(preferences, { type: "recording", recordings: [] },
    modelList(reverse ? [...entries].reverse() : entries), (id) => id);
  expect(resolve(false)).toEqual(resolve(true));
  expect(resolve(false)).toMatchObject({
    settings: { model: "gemini-3-8-flash", detail: "high" },
    input: { transcriptionModel: "gemini-3-8-flash" },
  });
  expect(preferences).toEqual(before);
  expect(summaryStyles.map(summaryStyleDetail)).toEqual(["low", "medium", "high", "xhigh", "max"]);
});

it("keeps inactive overrides and rejects unavailable explicit models and effort", () => {
  const preferences = structuredClone(DEFAULT_WORKSPACE_GENERATION_SETTINGS);
  preferences.processing = { location: "remote", remote: {
    workflow: "combined", summaryModel: "gemini-3-8-flash", transcriptionModel: "unavailable",
  } };
  const catalog = modelList([{ id: "gemini-3-8-flash" }]);
  const resolve = () => resolveSummaryPreferences(preferences, { type: "recording", recordings: [] }, catalog, (id) => id);
  expect(resolve().input).not.toHaveProperty("transcriptionModel");
  preferences.processing.remote.workflow = "transcribeThenSummarize";
  expect(resolve).toThrow("summary_invalid_audio_model");
  preferences.processing.remote.workflow = "combined";
  preferences.processing.remote.summaryModel = "unavailable";
  expect(resolve).toThrow("summary_invalid_structured_model");
  preferences.processing.remote.summaryModel = "gemini-3-8-flash";
  preferences.processing.remote.reasoningEffort = "ultra";
  expect(resolve).toThrow("summary_invalid_reasoning_effort");
  preferences.processing.location = "local";
  preferences.processing.remote.reasoningEffort = undefined;
  expect(resolve().settings.model).toBe("gemini-3-8-flash");
  expect(resolve().settings.transcription).toEqual(preferences.transcription);
});

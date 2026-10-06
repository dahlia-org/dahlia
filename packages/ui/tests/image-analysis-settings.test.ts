import { describe, expect, it } from "vitest";
import { effectiveScreenshotSelection, normalizeImageAnalysis, withImageAnalysis } from "../src/model/workspace-generation-settings";

describe("unified image analysis settings", () => {
  it("preserves a legacy selection choice when image search is toggled", () => {
    const old = { imageAnalysis: { enabled: true }, screenshotSelection: { model: "legacy-model", reasoningEffort: "high" as const } };
    const next = withImageAnalysis(old, { ...effectiveScreenshotSelection(old), enabled: false });
    expect(next).toEqual({ imageAnalysis: { enabled: false, model: "legacy-model", reasoningEffort: "high" } });
    expect(effectiveScreenshotSelection(next)).toEqual(old.screenshotSelection);
  });

  it("normalizes legacy-only inputs and preserves unrelated settings and absent defaults", () => {
    expect(normalizeImageAnalysis({ outputLanguage: "en", screenshotSelection: { model: "legacy", reasoningEffort: "high" as const } }))
      .toEqual({ outputLanguage: "en", imageAnalysis: { enabled: true, model: "legacy", reasoningEffort: "high" } });
    const defaults = { imageAnalysis: undefined, outputLanguage: "ja" };
    expect(normalizeImageAnalysis(defaults)).toBe(defaults);
    const normalized = normalizeImageAnalysis({ imageAnalysis: { enabled: false, model: "current" }, screenshotSelection: { model: "old", reasoningEffort: "high" as const } });
    expect(normalized).toEqual({ imageAnalysis: { enabled: false, model: "current" } });
    expect(normalizeImageAnalysis(normalized)).toEqual(normalized);
  });

  it("uses the image analysis pair without mixing in a legacy effort", () => {
    const settings = { imageAnalysis: { enabled: false, model: "analysis-model" }, screenshotSelection: { model: "legacy-model", reasoningEffort: "high" as const } };
    expect(effectiveScreenshotSelection(settings)).toEqual({ model: "analysis-model" });
    expect(withImageAnalysis(settings, { enabled: false })).toEqual({ imageAnalysis: { enabled: false } });
    expect(effectiveScreenshotSelection(withImageAnalysis(settings, { enabled: false }))).toEqual({});
  });
});

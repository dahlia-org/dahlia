import { expect, it } from "vitest";
import { z } from "zod";
import { summaryDocument, summaryResponseSchema } from "../src/summary/model";
import { summaryStartSchema } from "../src/summary/service";
import { DEFAULT_ACCOUNT_SETTINGS } from "../src/account-settings-model";
import { uuidV7 } from "../src/id";

it("excludes transcription overrides structurally from preference inputs while preserving legacy requests", () => {
  const input = { type: "recording", recordings: [{ micFileId: uuidV7(), systemFileId: null }] };
  const request = { id: uuidV7(), input, preferences: {
    processing: DEFAULT_ACCOUNT_SETTINGS.processing,
    summary: DEFAULT_ACCOUNT_SETTINGS.summary,
    outputLanguage: DEFAULT_ACCOUNT_SETTINGS.outputLanguage,
  } };
  expect(summaryStartSchema.safeParse(request).success).toBe(true);
  const overridden = { ...input, transcriptionModel: "gemini-3-8-flash" };
  expect(summaryStartSchema.safeParse({ ...request, input: overridden }).success).toBe(false);
  expect(summaryStartSchema.safeParse({ id: request.id, input: overridden, model: "gpt-5.4", detail: "high", outputLanguage: "ja" }).success).toBe(true);
  const schema = z.toJSONSchema(summaryStartSchema, { io: "input", unrepresentable: "any" });
  expect(JSON.stringify(schema.anyOf![2]!.properties!.input)).not.toContain('"transcriptionModel"');
  expect(JSON.stringify(schema.anyOf![0]!.properties!.input)).toContain('"transcriptionModel"');
});

it("omits maxItems and accepts arrays beyond every former limit", () => {
  const text = { text: "Item", transcript_ref: null };
  const block = { type: "paragraph", level: 1, content: text, items: [], language: "", image_id: "" };
  const value = {
    title: "Meeting", description: "Summary",
    sections: [
      { heading: "Large", blocks: [{ ...block, items: Array.from({ length: 501 }, () => ({ ...text, checked: false })) },
        ...Array.from({ length: 500 }, () => block)] },
      ...Array.from({ length: 100 }, () => ({ heading: "Section", blocks: [] })),
    ],
    tags: Array.from({ length: 101 }, () => "tag"),
    action_items: Array.from({ length: 501 }, () => ({ title: "Action", assignee: "" })),
  };
  expect(JSON.stringify(z.toJSONSchema(summaryResponseSchema))).not.toContain("maxItems");
  expect(summaryResponseSchema.safeParse(value).success).toBe(true);
  for (const invalid of [
    { ...value, title: "x".repeat(121) }, { ...value, sections: [] }, { ...value, tags: ["Invalid Tag"] },
    { ...value, sections: [{ heading: "Section", blocks: [{ ...block, level: 7 }] }] },
    { ...value, description: undefined }, { ...value, action_items: ["Action"] },
  ]) expect(summaryResponseSchema.safeParse(invalid).success).toBe(false);
  expect(() => summaryDocument({ ...value, sections: [{ heading: "Image", blocks: [{ ...block, type: "image", image_id: "unknown" }] }] }, new Set()))
    .toThrow("summary_invalid_image_reference");
});


it("normalizes legacy details without changing their meaning or reasoning effort", async () => {
  const { summaryDetailSchema, normalizeSummaryDetail, summaryDetails, DEFAULT_ACCOUNT_SETTINGS, accountSettingsPatchSchema } = await import("../src/account-settings-model");
  for (const [old, canonical] of [["concise", "low"], ["standard", "medium"], ["detailed", "high"], ["eventSession", "xhigh"]]) {
    expect(normalizeSummaryDetail(old!)).toBe(canonical);
    expect(accountSettingsPatchSchema.safeParse({ summary: { remote: { detail: old } } }).success).toBe(false);
  }
  expect(DEFAULT_ACCOUNT_SETTINGS.summary.style).toBe("detailed");
  expect(summaryDetails).toEqual(["low", "medium", "high", "xhigh", "max"]);
  for (const value of summaryDetails) expect(summaryDetailSchema.parse(value)).toBe(value);
  expect(summaryDetailSchema.safeParse("unknown").success).toBe(false);
  expect(accountSettingsPatchSchema.parse({ summary: { style: "eventTimeline" }, processing: { remote: { reasoningEffort: "low" } } }))
    .toEqual({ summary: { style: "eventTimeline" }, processing: { remote: { reasoningEffort: "low" } } });
  const { summaryInstructions } = await import("../src/summary/transcript");
  expect(summaryInstructions("en", "max")).toContain("event play-by-play");
});

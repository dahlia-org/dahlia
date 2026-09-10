import { z } from "zod";

export const outputLanguageSchema = z.enum(["ja", "en", "zh", "ko", "fr", "de", "es"]);
const analysisLanguages = z.object({
  scope: z.enum(["all", "selected"]),
  identifiers: z.array(z.string().regex(/^[a-z]{2,3}(?:-[A-Z][a-z]{3})?$/)).max(200)
    .transform((values) => [...new Set(values)].sort()),
}).strict().refine((value) => value.scope === "all" || value.identifiers.length > 0);

export const summaryModeSchema = z.enum(["local", "remote"]);
export const summaryDetails = ["low", "medium", "high", "xhigh", "max"] as const;
export function normalizeSummaryDetail(value: string): string {
  switch (value) {
    case "concise": return "low";
    case "standard": return "medium";
    case "detailed": return "high";
    case "eventSession": return "xhigh";
    default: return value;
  }
}
export const summaryDetailSchema = z.enum(summaryDetails);
export const summaryModelSettingsSchema = z.object({
  model: z.string().trim().min(1).max(200),
  reasoningEffort: z.enum(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]),
}).strict();
export const summaryStyles = ["concise", "standard", "detailed", "eventSummary", "eventTimeline"] as const;
export const summaryStyleSchema = z.enum(summaryStyles);
export function summaryStyleDetail(style: z.infer<typeof summaryStyleSchema>): z.infer<typeof summaryDetailSchema> {
  return { concise: "low", standard: "medium", detailed: "high", eventSummary: "xhigh", eventTimeline: "max" }[style] as z.infer<typeof summaryDetailSchema>;
}
const modelPreference = z.string().trim().min(1).max(200);
export const remoteProcessingSchema = z.object({
  workflow: z.enum(["transcribeThenSummarize", "combined"]),
  summaryModel: modelPreference.optional(),
  transcriptionModel: modelPreference.optional(),
  reasoningEffort: summaryModelSettingsSchema.shape.reasoningEffort.optional(),
}).strict();
export const processingSchema = z.object({ location: summaryModeSchema, remote: remoteProcessingSchema }).strict();
const summarySchema = z.object({ style: summaryStyleSchema }).strict();
export const generationPreferencesSchema = z.object({ outputLanguage: outputLanguageSchema, processing: processingSchema, summary: summarySchema }).strict();
export const accountSettingsSchema = generationPreferencesSchema.extend({ analysisLanguages }).strict();
export type AccountSettings = z.infer<typeof accountSettingsSchema>;
export const DEFAULT_ACCOUNT_SETTINGS: AccountSettings = {
  outputLanguage: "ja",
  processing: { location: "local", remote: { workflow: "transcribeThenSummarize" } },
  summary: { style: "detailed" },
  analysisLanguages: { scope: "all", identifiers: [] },
};
export const accountSettingsPatchSchema = z.object({
  outputLanguage: outputLanguageSchema.optional(), analysisLanguages: analysisLanguages.optional(),
  summary: summarySchema.partial().optional(),
  processing: z.object({
    location: summaryModeSchema.optional(),
    remote: remoteProcessingSchema.partial().extend({
      summaryModel: modelPreference.nullable().optional(),
      transcriptionModel: modelPreference.nullable().optional(),
      reasoningEffort: summaryModelSettingsSchema.shape.reasoningEffort.nullable().optional(),
    }).strict().optional(),
  }).strict().optional(),
  initialize: z.boolean().optional(),
}).strict().refine((patch) => {
  if (patch.initialize) {
    return patch.outputLanguage !== undefined && patch.analysisLanguages !== undefined;
  }
  if (patch.outputLanguage !== undefined || patch.analysisLanguages !== undefined) return true;
  return patch.summary?.style !== undefined || patch.processing?.location !== undefined || Object.keys(patch.processing?.remote ?? {}).length > 0;
});
export type AccountSettingsPatch = Omit<z.infer<typeof accountSettingsPatchSchema>, "initialize">;

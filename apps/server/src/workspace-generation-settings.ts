import { z } from "zod";

export const outputLanguageSchema = z.enum(["ja", "en", "zh", "ko", "fr", "de", "es"]);
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
export const transcriptionSettingsSchema = z.object({
    localeIdentifier: z.string().max(100).regex(/^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})*$/),
    automaticLanguageDetection: z.boolean(),
    languageScope: z.enum(["all", "selected"]),
    languageIdentifiers: z.array(z.string().regex(/^[a-z]{2,3}(?:-[A-Z][a-z]{3})?$/)).max(200),
    liveTranscriptDraft: z.boolean(),
}).strict().refine((value) => !value.automaticLanguageDetection || value.languageScope === "all" || value.languageIdentifiers.length > 0,
  { message: "Select at least one language for automatic detection", path: ["languageIdentifiers"] });
export const generationPreferencesSchema = z.object({ outputLanguage: outputLanguageSchema, processing: processingSchema, summary: summarySchema, transcription: transcriptionSettingsSchema }).strict();

export type GenerationPreferences = z.infer<typeof generationPreferencesSchema>;
export const DEFAULT_GENERATION_PREFERENCES: GenerationPreferences = {
  outputLanguage: "ja",
  processing: { location: "local", remote: { workflow: "transcribeThenSummarize" } },
  summary: { style: "detailed" },
  transcription: { localeIdentifier: "ja-JP", automaticLanguageDetection: false, languageScope: "all", languageIdentifiers: [], liveTranscriptDraft: false },
};
export const workspaceGenerationSettingsSchema = generationPreferencesSchema.extend({
  local: summaryModelSettingsSchema,
  automaticProcessing: z.boolean(),
}).strict();
export type WorkspaceGenerationSettings = z.infer<typeof workspaceGenerationSettingsSchema>;
export const DEFAULT_WORKSPACE_GENERATION_SETTINGS: WorkspaceGenerationSettings = {
  ...DEFAULT_GENERATION_PREFERENCES,
  local: { model: "gpt-5.6-luna", reasoningEffort: "high" },
  automaticProcessing: true,
};

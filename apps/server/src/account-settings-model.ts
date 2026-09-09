import { z } from "zod";

export const outputLanguageSchema = z.enum(["ja", "en", "zh", "ko", "fr", "de", "es"]);
const analysisLanguages = z.object({
  scope: z.enum(["all", "selected"]),
  identifiers: z.array(z.string().regex(/^[a-z]{2,3}(?:-[A-Z][a-z]{3})?$/)).max(200)
    .transform((values) => [...new Set(values)].sort()),
}).strict().refine((value) => value.scope === "all" || value.identifiers.length > 0);

const summaryMethodSchema = z.enum(["transcript", "cloudTranscription", "audio"]);
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
export const summaryDetailSchema = z.string().transform(normalizeSummaryDetail).pipe(z.enum(summaryDetails));
export const summaryModelSettingsSchema = z.object({
  model: z.string().trim().min(1).max(200),
  reasoningEffort: z.enum(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]),
}).strict();
const summarySchema = z.object({
  method: summaryMethodSchema,
  detail: summaryDetailSchema,
  methodSettings: z.object({ transcript: summaryModelSettingsSchema, audio: summaryModelSettingsSchema }).strict(),
}).strict();
export const accountSettingsSchema = z.object({ outputLanguage: outputLanguageSchema, analysisLanguages, summary: summarySchema }).strict();
export type AccountSettings = z.infer<typeof accountSettingsSchema>;
export const DEFAULT_ACCOUNT_SETTINGS: AccountSettings = {
  outputLanguage: "ja",
  summary: { method: "transcript", detail: "high", methodSettings: {
    transcript: { model: "gpt-5.4", reasoningEffort: "medium" },
    audio: { model: "gemini-3-8-flash", reasoningEffort: "medium" },
  } },
  analysisLanguages: { scope: "all", identifiers: [] },
};
export const accountSettingsPatchSchema = z.object({
  outputLanguage: outputLanguageSchema.optional(), analysisLanguages: analysisLanguages.optional(),
  summary: z.object({
    method: summaryMethodSchema.optional(),
    detail: summaryDetailSchema.optional(),
    methodSettings: z.object({ transcript: summaryModelSettingsSchema.partial().optional(), audio: summaryModelSettingsSchema.partial().optional() }).strict().optional(),
  }).strict().optional(),
  initialize: z.boolean().optional(),
}).strict().refine((patch) => {
  if (patch.initialize) {
    return patch.outputLanguage !== undefined && patch.analysisLanguages !== undefined;
  }
  if (patch.outputLanguage !== undefined || patch.analysisLanguages !== undefined) return true;
  const summary = patch.summary;
  if (summary?.method !== undefined || summary?.detail !== undefined) return true;
  return Object.values(summary?.methodSettings ?? {}).some((fields) => Object.keys(fields).length > 0);
});
export type AccountSettingsPatch = Omit<z.infer<typeof accountSettingsPatchSchema>, "initialize">;

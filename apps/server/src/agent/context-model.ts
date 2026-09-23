import { z } from "zod";

export const preferenceValues = {
  language: z.enum(["ja", "en", "zh", "ko", "es", "fr", "de", "pt"]),
  format: z.enum(["prose", "bullets", "code-first"]),
  detail: z.enum(["concise", "balanced", "detailed"]),
  explanation: z.string().trim().min(1).max(240),
};
export const preferencesSchema = z.object({ language: preferenceValues.language.nullable(),
  format: preferenceValues.format.nullable(), detail: preferenceValues.detail.nullable(), explanation: preferenceValues.explanation.nullable() }).strict();
export type Preferences = z.infer<typeof preferencesSchema>;
export const emptyPreferences: Preferences = { language: null, format: null, detail: null, explanation: null };
export const preferenceSettingsSchema = z.object({ revision: z.number().int().nonnegative(),
  automatic: z.boolean(), preferences: preferencesSchema }).strict();
export type PreferenceSettings = z.infer<typeof preferenceSettingsSchema>;
export const preferenceExtractionSchema = z.object({ candidates: z.array(z.object({
  key: z.enum(["language", "format", "detail", "explanation"]), value: z.string().max(240), evidence: z.string().min(1).max(500),
}).strict()).max(4) }).strict();
export type PreferenceExtraction = z.infer<typeof preferenceExtractionSchema>;

// Only direct, persistent requests can become cross-workspace preferences.
export function directPreferenceText(content: string) {
  return content.replace(/```[\s\S]*?```/g, "").replace(/`[^`]*`/g, "")
    .replace(/^[ \t]*>.*$/gm, "").replace(/[「『“][\s\S]*?[」』”]/g, "")
    .replace(/"[^"\n]*"/g, "");
}
export function validatedPreferences(content: string, extraction: PreferenceExtraction): Partial<Preferences> {
  // ponytail: conservative Japanese/English evidence gates; expand only with language-specific regression cases.
  const direct = directPreferenceText(content);
  const result: Partial<Preferences> = {};
  for (const { key, value, evidence } of extraction.candidates) {
    if (!direct.includes(evidence) || !/(今後|これから|いつも|普段|好み|prefer|always|from now on)/i.test(evidence)) continue;
    if (key === "explanation" && (!evidence.includes(value)
      || !/(説明|用語|専門|例示|読みやす|文体|explain|terminology|jargon|examples|writing style)/i.test(value))) continue;
    const parsed = preferenceValues[key].safeParse(value);
    if (parsed.success) Object.assign(result, { [key]: parsed.data });
  }
  return result;
}

const point = z.object({ text: z.string().min(1).max(1000), segmentIds: z.array(z.string().uuid()).min(1).max(10) }).strict();
export const liveNotesSchema = z.object({ topics: z.array(point).max(10), decisions: z.array(point).max(10),
  questions: z.array(point).max(10) }).strict();
export type LiveNotes = z.infer<typeof liveNotesSchema>;
export const emptyLiveNotes: LiveNotes = { topics: [], decisions: [], questions: [] };
export const liveSelectionSchema = z.object({ meetingId: z.string().uuid().nullable() }).strict();
export const liveStatusSchema = z.object({ meetingId: z.string().uuid().nullable(),
  status: z.enum(["off", "pending", "ready", "delayed", "ended"]), updatedAt: z.iso.datetime().nullable(),
  processedThrough: z.iso.datetime().nullable() }).strict();
export type LiveStatus = z.infer<typeof liveStatusSchema>;
export const liveSnapshotSchema = z.object({ after: z.string(), notes: liveNotesSchema,
  recent: z.array(z.object({ segmentId: z.string().uuid(), text: z.string(), startedAt: z.string(),
    speakerLabel: z.string().nullable(), audioSource: z.string().nullable(), truncated: z.boolean() })).max(20),
  truncated: z.boolean(),
  processedThrough: z.string().nullable(), updatedAt: z.string() });
export type LiveSnapshot = z.infer<typeof liveSnapshotSchema>;

import { z } from "zod";

export const workingMemoryContentSchema = z.string().trim().max(6000);
export const workingMemorySettingsSchema = z.object({ revision: z.number().int().nonnegative(), automatic: z.boolean(), capacityReached: z.boolean(),
  manual: workingMemoryContentSchema, learned: workingMemoryContentSchema }).strict();
export type WorkingMemorySettings = z.infer<typeof workingMemorySettingsSchema>;
export const workingMemoryEditSchema = z.discriminatedUnion("section", [
  z.object({ section: z.enum(["manual", "learned"]), content: workingMemoryContentSchema,
    revision: z.number().int().nonnegative(), explicit: z.boolean() }).strict(),
  z.object({ section: z.literal("settings"), automatic: z.boolean(), revision: z.number().int().nonnegative(), explicit: z.literal(true) }).strict(),
]);
export type WorkingMemoryEdit = z.infer<typeof workingMemoryEditSchema>;
export const workingMemoryExtractionSchema = z.object({ evidence: z.string().max(500),
  note: z.string().trim().max(500) }).strict();

// Only direct, persistent user statements can become cross-client memory.
export function directMemoryText(content: string) {
  return content.replace(/```[\s\S]*?```/g, "").replace(/`[^`]*`/g, "")
    .replace(/^[ \t]*>.*$/gm, "").replace(/[「『“][\s\S]*?[」』”]/g, "")
    .replace(/"[^"\n]*"/g, "");
}
export function validatedMemoryNote(content: string, extraction: z.infer<typeof workingMemoryExtractionSchema>): string | null {
  const direct = directMemoryText(content);
  if (!extraction.evidence || !extraction.note || !direct.includes(extraction.evidence)
    || !/(今後|これから|いつも|普段|覚えて|記憶して|prefer|always|from now on|remember|my preference)/i.test(extraction.evidence)
    || /(password|api.?key|access.?token|secret|private.?key|パスワード|秘密鍵|トークン|認証情報)/i.test(extraction.evidence + extraction.note)) return null;
  return extraction.note.replace(/[\r\n]+/g, " ");
}

const point = z.object({ text: z.string().min(1).max(1000), segmentIds: z.array(z.string().uuid()).min(1).max(10) }).strict();
export const liveNotesSchema = z.object({ topics: z.array(point).max(10), decisions: z.array(point).max(10),
  questions: z.array(point).max(10) }).strict();
export type LiveNotes = z.infer<typeof liveNotesSchema>;
export const emptyLiveNotes: LiveNotes = { topics: [], decisions: [], questions: [] };
export const liveSelectionSchema = z.object({ meetingId: z.string().uuid().nullable() }).strict();
export const liveStatusSchema = z.object({ meetingId: z.string().uuid().nullable(),
  status: z.enum(["off", "pending", "ready", "delayed", "ended", "unavailable"]), updatedAt: z.iso.datetime().nullable(),
  processedThrough: z.iso.datetime().nullable() }).strict();
export type LiveStatus = z.infer<typeof liveStatusSchema>;
export const liveSnapshotSchema = z.object({ after: z.string(), notes: liveNotesSchema,
  recent: z.array(z.object({ segmentId: z.string().uuid(), text: z.string(), startedAt: z.string(),
    speakerLabel: z.string().nullable(), audioSource: z.string().nullable(), truncated: z.boolean() })).max(20),
  truncated: z.boolean(),
  processedThrough: z.string().nullable(), updatedAt: z.string() });
export type LiveSnapshot = z.infer<typeof liveSnapshotSchema>;

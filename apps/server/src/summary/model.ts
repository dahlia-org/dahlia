import type { GeneratedTranscript } from "./transcription";
import type { SummaryMetadata } from "./metadata";
import type { GenerationPreferences } from "./preferences";
import { z } from "zod";
import type { AccountSettings } from "../account-settings";
import { uuidV7 } from "../id";
import type { IdentitySyncStore } from "../sync/types";

import { normalizeSummaryDetail, summaryDetailSchema, summaryModelSettingsSchema } from "../account-settings-model";
export { summaryDetailSchema } from "../account-settings-model";
export const transcriptSettingsSchema = summaryModelSettingsSchema.extend({ detail: summaryDetailSchema, transcriptionReasoningEffort: summaryModelSettingsSchema.shape.reasoningEffort.optional() });
// Accepted jobs retain their captured settings across API contract changes.
export const storedTranscriptSettingsSchema = transcriptSettingsSchema.extend({
  detail: z.string().transform(normalizeSummaryDetail).pipe(summaryDetailSchema),
});
export type TranscriptSettings = z.infer<typeof transcriptSettingsSchema>;
const contentVersion = z.string().min(1).max(200);
export const summaryInputSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("transcript"), version: contentVersion }).strict(),
  z.object({ type: z.literal("recording"), recordings: z.array(z.object({
    micFileId: z.uuid().transform((value) => value.toLowerCase()).nullable(),
    systemFileId: z.uuid().transform((value) => value.toLowerCase()).nullable(),
  }).strict().refine((pair) => pair.micFileId !== null || pair.systemFileId !== null)).min(1).max(1000)
    .refine((pairs) => { const ids = pairs.flatMap((pair) => [pair.micFileId, pair.systemFileId]).filter((id) => id !== null); return new Set(ids).size === ids.length; }),
    transcriptionModel: z.string().trim().min(1).max(200).optional() }).strict(),
]);
export type SummaryInput = z.infer<typeof summaryInputSchema>;
export type SummaryStage = "transcribing" | "summarizing" | "generating" | "saving";
export interface SummaryTranscriptResult {
  transcriptId: string; version: string;
}
export type SummaryGenerationResult = SummaryDocument & { transcript?: GeneratedTranscript };
export interface SummaryJob {
  id: string; vaultId: string; meetingId: string; ownerUserId: string;
  method: "transcript" | "audio"; settings: TranscriptSettings; outputLanguage: string;
  status: string; attempts: number; createdAt: Date; availableAt: Date;
  claimedAt: Date | null; leaseExpiresAt: Date | null; lastErrorCode: string | null;
  input?: SummaryInput | null; stage?: SummaryStage | null;
  transcriptRevision?: number | null; transcriptResult?: SummaryTranscriptResult | null;
  summaryRevision: number; inputVersion: string; requestHash: string;
}
export class SummaryError extends Error {
  constructor(readonly code: string, readonly retryable = false,
    readonly requestId?: string) { super(code); }
}
const text = z.object({ text: z.string().max(20000), transcript_ref: z.null() }).strict();
const block = z.object({
  type: z.enum(["paragraph", "bulleted_list", "numbered_list", "checklist", "quote", "code", "image", "heading"]),
  level: z.number().int().min(1).max(6), content: text,
  items: z.array(text.extend({ checked: z.boolean() })),
  language: z.string().max(100), image_id: z.string().max(36),
}).strict();
export const summaryResponseSchema = z.object({
  title: z.string().trim().min(1).max(120), description: z.string().trim().min(1).max(240),
  sections: z.array(z.object({ heading: z.string().max(500), blocks: z.array(block) }).strict()).min(1),
  tags: z.array(z.string().regex(/^[a-z0-9_]*[a-z][a-z0-9_]*$/)),
  action_items: z.array(z.object({ title: z.string().min(1).max(2000), assignee: z.string().max(500) }).strict()),
}).strict();
export function summaryDocument(value: unknown, imageIds: ReadonlySet<string>) {
  const response = summaryResponseSchema.parse(value);
  return {
    schemaVersion: 3, title: response.title, description: response.description,
    tags: response.tags, actionItems: response.action_items,
    sections: response.sections.map((section) => ({ id: uuidV7(), heading: section.heading,
      blocks: section.blocks.map((item) => {
        const base = { id: uuidV7(), type: item.type };
        switch (item.type) {
          case "image":
            if (!imageIds.has(item.image_id)) throw new SummaryError("summary_invalid_image_reference");
            return { ...base, screenshot_id: item.image_id, content: item.content };
          case "checklist": return { ...base, items: item.items };
          case "bulleted_list": case "numbered_list":
            return { ...base, items: item.items.map(({ text, transcript_ref }) => ({ text, transcript_ref })) };
          case "code": return { ...base, language: item.language, content: item.content };
          case "heading": return { ...base, level: item.level, content: item.content };
          default: return { ...base, content: item.content };
        }
      }),
    })),
  };
}
export type SummaryDocument = ReturnType<typeof summaryDocument> & { metadata?: SummaryMetadata };
export interface SummaryMethod {
  readonly id: SummaryJob["method"];
  captureSettings(settings: AccountSettings, detail?: z.infer<typeof summaryDetailSchema>): SummaryJob["settings"];
  resolvePreferences?(preferences: GenerationPreferences, input: SummaryInput): Promise<{ settings: TranscriptSettings; input: SummaryInput }>;
  validateSettings?(settings: TranscriptSettings, input?: SummaryInput): Promise<void>;
  version(store: IdentitySyncStore, vaultId: string, meetingId: string, input?: SummaryInput | null): Promise<string>;
  transcribe?(job: SummaryJob, signal: AbortSignal): Promise<GeneratedTranscript>;
  generate(job: SummaryJob, signal: AbortSignal): Promise<SummaryGenerationResult>;
}

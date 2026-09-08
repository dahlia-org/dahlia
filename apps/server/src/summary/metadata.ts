import { z } from "zod";

const reasoning = z.object({ effort: z.string().max(100).nullish(), summary: z.string().max(100).nullish() });
const tokens = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).nullish();
export const summaryResponseMetadataSchema = z.object({
  id: z.string().max(500).nullish(),
  model: z.string().max(500).nullish(),
  created_at: z.number().finite().nullish(),
  reasoning: reasoning.nullish(),
  usage: z.object({
    input_tokens: tokens,
    output_tokens: tokens,
    total_tokens: tokens,
    input_tokens_details: z.object({ cached_tokens: tokens }).nullish(),
    output_tokens_details: z.object({ reasoning_tokens: tokens }).nullish(),
  }).nullish(),
});
export const summaryMetadataSchema = z.object({
  generatedBy: z.enum(["server", "local_codex"]),
  inputTypes: z.array(z.enum(["transcript", "image", "audio", "note", "context"])).max(5),
  detailLevel: z.string().max(100).nullish(),
  outputLanguage: z.string().max(100).nullish(),
  request: z.object({ model: z.string().max(500).nullish(), reasoning: reasoning.optional() }),
  response: summaryResponseMetadataSchema.optional(),
});
export type SummaryMetadata = z.infer<typeof summaryMetadataSchema>;

export function summaryMetadata(document: string): SummaryMetadata | null {
  try {
    const value: unknown = JSON.parse(document);
    const parsed = z.object({ metadata: summaryMetadataSchema }).safeParse(value);
    return parsed.success ? parsed.data.metadata : null;
  } catch { return null; }
}

export interface SummaryVersion {
  vaultId: string;
  meetingId: string;
  revision: number;
  title: string;
  document: string;
  createdAt: Date | null;
  savedAt: Date;
  metadata: SummaryMetadata | null;
}

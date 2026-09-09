import transcriptPolicy from "./transcript-policy.json";
import { z } from "zod";
import { summaryResponseMetadataSchema } from "../summary/metadata";

const date = z.iso.datetime();
const locale = z.string().min(1).max(100);
export const transcriptMetadataSchema = z.object({
  provider: z.string().min(1).max(100),
  request: z.object({ model: z.string().min(1).max(500) }).strict(),
  runs: z.array(z.object({
    generatedBy: z.enum(["desktop", "server"]),
    inputTypes: z.array(z.literal("audio")).min(1).max(1),
    startedAt: date.nullish(),
    completedAt: date.nullish(),
    language: z.object({ mode: z.enum(["auto", "fixed"]), locales: z.array(locale).max(100) }).strict().optional(),
    recognitionLocales: z.array(locale).max(100).optional(),
    response: summaryResponseMetadataSchema.optional(),
    recordingSessionId: z.uuid().optional(),
    audioInputs: z.array(z.object({ recordingNumber: z.number().int().positive(), source: z.enum(["mic", "system"]),
      checksum: z.string().regex(/^SHA-256:[a-f0-9]{64}$/) }).strict()).min(1).max(2000).optional(),
  }).strict()).min(1).max(1000),
}).strict().refine((value) => new TextEncoder().encode(JSON.stringify(value)).length <= 256 * 1024, "Transcript metadata is too large");

export type TranscriptMetadata = z.infer<typeof transcriptMetadataSchema>;
export const transcriptWriteSchema = z.object({
  id: z.uuid().transform((value) => value.toLowerCase()),
  startedAt: date.nullish().transform((value) => value ? new Date(value) : null),
  endedAt: date.nullish().transform((value) => value ? new Date(value) : null),
  metadata: transcriptMetadataSchema.nullish().transform((value) => value ?? null),
}).strict();

export interface TranscriptVersion {
  id: string;
  meetingId: string;
  version: number;
  syncRevision: number;
  status: TranscriptStatus;
  latestSegmentCreatedAt: Date | null;
  startedAt: Date | null;
  endedAt: Date | null;
  createdAt: Date;
  metadata: TranscriptMetadata | null;
}

export function sameTranscriptModel(left: TranscriptMetadata | null, right: TranscriptMetadata | null) {
  return !!left && !!right && left.provider === right.provider && left.request.model === right.request.model;
}

// Five minutes tolerates pauses and delayed delivery; this is activity, not recording liveness.
export const TRANSCRIPT_ACTIVITY_WINDOW_MS = transcriptPolicy.activityWindowSeconds * 1000;
export type TranscriptStatus = "ended" | "active" | "inactive" | "unknown";
export function transcriptStatus(endedAt: Date | null, latestSegmentCreatedAt: Date | null, now = new Date()): TranscriptStatus {
  if (endedAt) return "ended";
  if (!latestSegmentCreatedAt) return "unknown";
  return now.getTime() - latestSegmentCreatedAt.getTime() <= TRANSCRIPT_ACTIVITY_WINDOW_MS ? "active" : "inactive";
}

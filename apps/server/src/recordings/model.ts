import { z } from "zod";

export const RECORDING_MAX_BYTES = 1024 * 1024 * 1024;
export const recordingSourceSchema = z.enum(["mic", "system"]);
export type RecordingSource = z.infer<typeof recordingSourceSchema>;
export const recordingManifestSchema = z.object({
  sampleRate: z.literal(16000),
  frameCount: z.number().int().positive().max(16000 * 60 * 60 * 48),
  ranges: z.array(z.object({
    startFrame: z.number().int().nonnegative(),
    frameCount: z.number().int().positive(),
    sessionOffsetSeconds: z.number().finite().nonnegative(),
    localeIdentifier: z.string().min(1).max(100),
  }).strict()).min(1).max(10000),
}).strict().superRefine((value, context) => {
  let end = 0;
  for (const range of value.ranges) {
    if (range.startFrame < end || range.startFrame + range.frameCount > value.frameCount) {
      context.addIssue({ code: "custom", message: "Invalid recording range" });
    }
    end = range.startFrame + range.frameCount;
  }
});
export type RecordingManifest = z.infer<typeof recordingManifestSchema>;
export interface RecordingAudio {
  generation: string;
  createdAt: string;
  uploadedAt: string | null;
  active: boolean;
  content_type: "audio/mp4";
  size: number;
  checksum: string | null;
  manifest?: RecordingManifest;
}
export interface RecordingRecord {
  sessionId: string;
  vaultId: string;
  meetingId: string;
  number: number;
  startedAt: Date;
  endedAt: Date;
  audio: Partial<Record<RecordingSource, RecordingAudio>>;
  revision: number;
  createdAt: Date;
  updatedAt: Date;
}
export const recordingStorageKey = (record: Pick<RecordingRecord, "meetingId" | "number">, source: RecordingSource) =>
  `meetings/${record.meetingId}/recordings/audio_${source}_${String(record.number).padStart(2, "0")}.m4a`;
export const recordingContentURL = (record: Pick<RecordingRecord, "meetingId" | "number">, source: RecordingSource) =>
  `/api/v1/meetings/${record.meetingId}/recordings/${record.number}/audio/${source}`;
export function recordingResponse(record: RecordingRecord, includeStaging = false) {
  const audio = Object.fromEntries(Object.entries(record.audio).filter(([, value]) => value.uploadedAt && (value.active || includeStaging))
    .map(([source, value]) => [source, {
      content_type: value.content_type, size: value.size, checksum: value.checksum,
      contentURL: recordingContentURL(record, source as RecordingSource),
    }]));
  return { id: record.number, startedAt: record.startedAt, endedAt: record.endedAt, audio };
}
export function recordingCanonical(record: RecordingRecord) {
  return { ...recordingResponse(record), recordingNumber: record.number, sessionId: record.sessionId, meetingId: record.meetingId,
    vaultId: record.vaultId, revision: record.revision,
    audio: Object.fromEntries(Object.entries(record.audio).filter(([, value]) => value.active).map(([source, value]) => [source, {
      content_type: value.content_type, size: value.size, checksum: value.checksum, manifest: value.manifest,
      contentURL: recordingContentURL(record, source as RecordingSource),
    }])),
  };
}

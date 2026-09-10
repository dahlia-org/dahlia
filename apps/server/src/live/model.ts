import { z } from "zod";
import { sha256 } from "../storage/sha256";
import { RequestError } from "../storage/upload";

const id = z.uuid().transform((value) => value.toLowerCase());
export const liveSpeechSchema = z.object({
  id, startedAt: z.iso.datetime({ offset: true }), endedAt: z.iso.datetime({ offset: true }).nullish(), text: z.string().max(16000),
  audioSource: z.string().max(200).nullish(), speakerLabel: z.string().max(200).nullish(),
}).strict();
export const liveStateSchema = z.object({
  vaultId: id, meetingId: id, sessionId: id, startedAt: z.iso.datetime({ offset: true }),
  status: z.enum(["recording", "disabled", "stopped", "failed"]),
  sequence: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  updatedAt: z.iso.datetime({ offset: true }), previews: z.array(liveSpeechSchema).max(8),
}).strict().refine((state) => state.status === "recording" || state.previews.length === 0, "Inactive sessions cannot publish previews")
  .refine((state) => new Set(state.previews.map((preview) => preview.audioSource ?? "")).size === state.previews.length, "One preview per source");
export type LiveSpeech = z.infer<typeof liveSpeechSchema>;
export type LiveState = z.infer<typeof liveStateSchema>;
export interface StoredLiveState { vaultId: string; meetingId: string; sessionId: string; startedAt: Date; sequence: number; status: LiveState["status"]; updatedAt: Date; previews: LiveSpeech[] }
export const LIVE_EXPIRY_MS = 45_000;
export function visibleLiveState(row: StoredLiveState, now = new Date()) {
  const expired = now.getTime() - row.updatedAt.getTime() > LIVE_EXPIRY_MS;
  return { ...row, status: expired && ["recording", "disabled"].includes(row.status) ? "disconnected" as const : row.status,
    previews: expired ? [] : row.previews };
}
const cursorSchema = z.object({ vaultId: z.uuid(), meetingId: z.uuid(), sessionId: z.uuid(), generation: z.string(),
  position: z.number().int().nonnegative(), digest: z.string() }).strict();
export const liveQuery = z.object({ cursor: z.string().max(2048).optional(), limit: z.coerce.number().int().min(1).max(500).default(200) }).strict();

// ponytail: O(n) prefix verification detects edits and late inserts without a second transcript journal; add a journal if long-meeting reads become costly.
export async function livePage(state: ReturnType<typeof visibleLiveState>, generation: string, segments: LiveSpeech[], cursor: string | undefined, limit: number) {
  let position = 0;
  let resetRequired = false;
  const digest = (end: number) => sha256(JSON.stringify(segments.slice(0, end)));
  if (cursor) {
    let previous: z.infer<typeof cursorSchema>;
    try { previous = cursorSchema.parse(JSON.parse(atob(cursor))); } catch { throw new RequestError(400, "invalid_live_cursor"); }
    if (previous.vaultId !== state.vaultId || previous.meetingId !== state.meetingId) throw new RequestError(400, "invalid_live_cursor");
    if (previous.sessionId !== state.sessionId || previous.generation !== generation || previous.position > segments.length
      || previous.digest !== await digest(previous.position)) resetRequired = true;
    else position = previous.position;
  }
  const end = Math.min(segments.length, position + limit);
  const next = btoa(JSON.stringify({ vaultId: state.vaultId, meetingId: state.meetingId, sessionId: state.sessionId,
    generation, position: end, digest: await digest(end) }));
  return { state, confirmedState: generation === "none" ? "not_synced" as const : "last_synced" as const,
    confirmedThrough: segments.reduce<string | null>((latest, item) => !latest || item.startedAt > latest ? item.startedAt : latest, null),
    confirmed: segments.slice(position, end), cursor: next, hasMore: end < segments.length, resetRequired };
}

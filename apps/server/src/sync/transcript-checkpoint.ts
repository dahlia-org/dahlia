import { z } from "zod";
import { sha256 } from "../storage/sha256";
import { RequestError } from "../storage/upload";

const checkpointSchema = z.object({ workspaceId: z.uuid(), meetingId: z.uuid(), generation: z.string(),
  position: z.number().int().nonnegative(), digest: z.string() }).strict();

// ponytail: O(n) prefix verification catches edits, deletions and late inserts; use a change journal if long-meeting reads become costly.
export async function transcriptCheckpoint<T>(workspaceId: string, meetingId: string, generation: string,
  records: T[], after: string | undefined, start: number, limit: number) {
  const digest = (end: number) => sha256(JSON.stringify(records.slice(0, end)));
  if (after !== undefined) {
    let previous: z.infer<typeof checkpointSchema>;
    try {
      if (after.length > 2048) throw new Error();
      previous = checkpointSchema.parse(JSON.parse(atob(after)));
    } catch { throw new RequestError(400, "invalid_transcript_after"); }
    if (previous.workspaceId !== workspaceId || previous.meetingId !== meetingId) throw new RequestError(400, "invalid_transcript_after");
    if ((previous.generation !== generation && previous.generation !== "none") || previous.position > records.length
      || previous.digest !== await digest(previous.position)) throw new RequestError(409, "transcript_changed_refetch_without_after");
    start = previous.position;
  }
  const end = Math.min(records.length, start + limit);
  return { items: records.slice(start, end), hasMore: end < records.length,
    next_after: btoa(JSON.stringify({ workspaceId, meetingId, generation, position: end, digest: await digest(end) })) };
}

export function waitForTranscript(signal?: AbortSignal) {
  return new Promise<void>((resolve, reject) => {
    const abort = () => { clearTimeout(timer); signal?.removeEventListener("abort", abort); reject(signal?.reason instanceof Error ? signal.reason : new Error("Request aborted")); };
    const timer = setTimeout(() => { signal?.removeEventListener("abort", abort); resolve(); }, 250);
    signal?.addEventListener("abort", abort, { once: true });
    if (signal?.aborted) abort();
  });
}

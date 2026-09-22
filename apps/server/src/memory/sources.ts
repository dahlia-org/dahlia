import type { Identity } from "../auth/identity";
import type { MeetingSyncService } from "../sync/service";
import { HindsightError } from "./hindsight";
import type { MemoryDocument } from "./model";
import type { SharedMemory } from "./store";

export async function contentHash(content: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(content));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
export function noteDocument(note: SharedMemory): MemoryDocument {
  return { id: `shared-${note.id}`, source: { kind: "shared", id: note.id, revision: String(note.revision), projectId: null },
    content: `User-registered shared information (not independently verified):\n${note.content}`, timestamp: note.updatedAt.toISOString() };
}
export async function meetingDocument(sync: MeetingSyncService, identity: Identity, workspaceId: string, meetingId: string,
  signal: AbortSignal): Promise<MemoryDocument | null> {
  const meeting = await sync.getMeeting(identity, workspaceId, meetingId);
  if (!meeting || meeting.isRecording || meeting.status !== "READY") return null;
  const parts = [`Meeting ${meeting.meetingId}; date ${(meeting.recordingStartedAt ?? meeting.createdAt).toISOString()}`,
    `Title: ${meeting.name}\nUser description: ${meeting.description}`];
  if (meeting.projectId) {
    const project = await sync.getProject(identity, workspaceId, meeting.projectId);
    if (project) parts.push(`Project ${project.projectId}: ${project.name}\n${project.description}`);
  }
  let cursor: string | undefined;
  let bytes = 0;
  const append = (text: string) => {
    bytes += new TextEncoder().encode(text).byteLength;
    if (bytes > 4 * 1024 * 1024) throw new HindsightError("memory_source_too_large");
    parts.push(text);
  };
  do {
    signal.throwIfAborted();
    const page = await sync.listTranscript(identity, workspaceId, meetingId, cursor);
    for (const segment of page.items) append(`[Transcript segment ${segment.segmentId}; ${segment.startedAt.toISOString()}; speaker ${segment.speakerLabel ?? "unknown"}; ${segment.audioSource ?? "unknown source"}] ${segment.text}`);
    cursor = page.nextCursor;
  } while (cursor);
  if (meeting.summaryDocument) append(`AI-generated summary (same meeting evidence, not independent corroboration):\n${meeting.summaryDocument}`);
  do {
    signal.throwIfAborted();
    const page = await sync.listScreenshots(identity, workspaceId, meetingId, undefined, signal, cursor);
    for (const shot of page.items) {
      if (shot.ocrText || shot.caption) append(`[Screenshot ${shot.screenshotId}; file ${shot.fileId}; ${shot.capturedAt.toISOString()}]\nOCR (screen text, not speech): ${shot.ocrText ?? ""}\nAI caption (interpretation): ${shot.caption ?? ""}`);
    }
    cursor = page.nextCursor;
  } while (cursor);
  const content = parts.join("\n\n");
  return { id: `meeting-${meetingId}`, source: { kind: "meeting", id: meetingId, projectId: meeting.projectId,
    revision: await contentHash(content) }, content, timestamp: (meeting.recordingStartedAt ?? meeting.createdAt).toISOString() };
}

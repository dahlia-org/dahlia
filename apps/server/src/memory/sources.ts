import type { Identity } from "../auth/identity";
import type { MeetingSyncService } from "../sync/service";
import { HindsightError } from "./errors";
import type { MemoryDocument } from "./model";
import type { SharedMemory } from "./store";
import { memoryDocumentId } from "./ids";

export async function contentHash(content: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(content));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
export function noteDocument(note: SharedMemory, personal = false): MemoryDocument {
  return { id: memoryDocumentId("shared", note.id), source: { kind: "shared", id: note.id, revision: String(note.revision), projectId: null },
    content: `${personal ? "Private user memory" : "User-registered shared information"} (not independently verified):\n${note.content}`, timestamp: note.updatedAt.toISOString() };
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
  const screenshots: import("../sync/types").SyncScreenshotRecord[] = [];
  const screenshotPositions: NonNullable<MemoryDocument["screenshotPositions"]> = {};
  let cursor: string | undefined;
  let bytes = 0;
  const markers = new Map<number, string>();
  const append = (text: string, marker?: string) => {
    bytes += new TextEncoder().encode(text).byteLength;
    if (bytes > 4 * 1024 * 1024) throw new HindsightError("memory_source_too_large");
    if (marker) markers.set(parts.length, marker);
    parts.push(text);
  };
  do {
    signal.throwIfAborted();
    const page = await sync.listTranscript(identity, workspaceId, meetingId, cursor);
    for (const segment of page.items) append(`[Transcript segment ${segment.segmentId}; ${segment.startedAt.toISOString()}; speaker ${segment.speakerLabel ?? "unknown"}; ${segment.audioSource ?? "unknown source"}] ${segment.text}`, `Transcript segment ${segment.segmentId}`);
    cursor = page.nextCursor;
  } while (cursor);
  if (meeting.summaryDocument) append(`AI-generated summary (same meeting evidence, not independent corroboration):\n${meeting.summaryDocument}`);
  do {
    signal.throwIfAborted();
    const page = await sync.listScreenshots(identity, workspaceId, meetingId, undefined, signal, cursor);
    screenshots.push(...page.items);
    for (const shot of page.items) {
      screenshotPositions[shot.screenshotId] = { blockIndex: parts.length, textBlock: !!(shot.ocrText || shot.caption) };
      if (shot.ocrText || shot.caption) append(`[Screenshot ${shot.screenshotId}; file ${shot.fileId}; ${shot.capturedAt.toISOString()}]\nOCR (screen text, not speech): ${shot.ocrText ?? ""}\nAI caption (interpretation): ${shot.caption ?? ""}`, `Screenshot ${shot.screenshotId}`);
    }
    cursor = page.nextCursor;
  } while (cursor);
  const content = parts.join("\n\n");
  let offset = 0;
  const blocks = parts.map((part, index) => {
    const start = offset;
    offset += part.length + 2;
    return { start, end: start + part.length, marker: markers.get(index) };
  });
  return { id: memoryDocumentId("meeting", meetingId), source: { kind: "meeting", id: meetingId, projectId: meeting.projectId,
    revision: await contentHash(content) }, content, blocks, screenshots, screenshotPositions, timestamp: (meeting.recordingStartedAt ?? meeting.createdAt).toISOString() };
}

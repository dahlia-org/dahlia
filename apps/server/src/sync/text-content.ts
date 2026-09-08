import { IncrementalSha256 } from "../storage/sha256";
import type { IdentitySyncStore, SyncCanonicalRecord, SyncTranscriptCursor } from "./types";
import { SyncTransactionError } from "./store";

export const TEXT_CONTENT_VERSION = 1;
export const METADATA_CONTENT_MODE = "metadata-v1";
export type TextEntity = "summary" | "transcript" | "file";

/** Each nullable UTF-8 field is framed by its decimal byte length and ':'. Null is '-:'.
 * Transcript fields are segment UUID (lowercase), text, in (startTime, UUID) order.
 * Summary has one document field; file text has OCR followed by caption. */
export class TextContentDigest {
  private readonly hash = new IncrementalSha256();
  private readonly encoder = new TextEncoder();
  byteCount = 0;

  add(value: string | null, body = true) {
    const bytes = value === null ? null : this.encoder.encode(value);
    this.hash.update(this.encoder.encode(bytes === null ? "-:" : `${bytes.length}:`));
    if (bytes !== null) this.hash.update(bytes);
    if (body) this.byteCount += bytes?.length ?? 0;
  }

  digestHex() { return this.hash.digestHex(); }
}

export function parseTextEntity(value: string): TextEntity {
  if (value !== "transcript" && value !== "file") {
    throw new SyncTransactionError(400, "invalid_text_entity");
  }
  return value;
}

export function parseContentMode(value?: string) {
  if (value !== undefined && value !== METADATA_CONTENT_MODE) throw new SyncTransactionError(400, "invalid_content_mode");
  return value;
}

export function fileTextMetadata(record: Record<string, unknown>): Record<string, unknown> {
  const metadata = { ...(record.metadata ?? {}) as Record<string, unknown> };
  delete metadata.ocr_text;
  delete metadata.caption;
  return { ...record, metadata, contentOmitted: true, contentPresent: true };
}

export function meetingMetadata(record: Record<string, unknown>): Record<string, unknown> {
  // Canonical meeting rows also contain search projections and the summary document.
  const keys = ["meetingId", "vaultId", "projectId", "name", "description", "status", "duration",
    "recordingStartedAt", "isRecording", "createdAt", "updatedAt", "revision", "summaryRevision", "transcriptRevision", "active", "deletingAt"];
  const hasSummary = record.summaryDocument !== null && record.summaryDocument !== undefined;
  return { ...Object.fromEntries(keys.filter((key) => key in record).map((key) => [key, record[key]])), contentOmitted: true, hasSummary };
}

export async function metadataRecord(value: SyncCanonicalRecord, store: IdentitySyncStore, vaultId: string): Promise<SyncCanonicalRecord> {
  if (!value.record) return value;
  let record: Record<string, unknown> = { ...value.record };
  if (value.entity === "meeting") {
    record = meetingMetadata(record);
  } else if (value.entity === "summary") {
    record = { meetingId: record.meetingId, title: record.title, createdAt: record.createdAt,
      contentOmitted: true, contentPresent: record.document !== null && record.document !== undefined };
  } else if (value.entity === "transcript") {
    record = { meetingId: record.meetingId, contentOmitted: true, contentPresent: true,
      contentCount: await store.countTranscript(vaultId, value.id) };
  } else if (value.entity === "file") {
    record = fileTextMetadata(record);
  }
  return { ...value, record };
}

/** The caller holds the Vault lock within its identity transaction, including every revision check. */
export async function readTextContent(
  store: IdentitySyncStore, vaultId: string, entity: TextEntity, entityId: string,
  revision: number, manifestOnly: boolean, after?: SyncTranscriptCursor,
) {
  const digest = new TextContentDigest();
  let count = 0;
  let present = true;
  let record: Record<string, unknown> | undefined;
  let items: Awaited<ReturnType<IdentitySyncStore["listTranscript"]>> | undefined;
  let nextCursor: string | null = null;
  if (!await store.getVault(vaultId)) throw new SyncTransactionError(404, "vault_not_found");
  if (entity === "file") {
    const file = await store.getFile(entityId, true);
    if (!file || file.vaultId !== vaultId) throw new SyncTransactionError(404, "file_not_found");
    assertRevision(file.revision, revision);
    digest.add(file.metadata.ocr_text ?? null);
    digest.add(file.metadata.caption ?? null);
    count = 2;
    record = { ocr_text: file.metadata.ocr_text ?? null, caption: file.metadata.caption ?? null };
  } else {
    const meeting = await store.getMeeting(vaultId, entityId);
    if (!meeting) throw new SyncTransactionError(404, "meeting_not_found");
    assertRevision((entity === "summary" ? meeting.summaryRevision : meeting.transcriptRevision) ?? 0, revision);
    if (entity === "summary") {
      present = meeting.summaryDocument !== null;
      digest.add(meeting.summaryDocument);
      count = present ? 1 : 0;
      record = { title: meeting.summaryTitle, document: meeting.summaryDocument, createdAt: meeting.summaryCreatedAt };
    } else {
      let cursor = after;
      do {
        const rows = await store.listTranscript(vaultId, entityId, 501, cursor);
        const page = [] as typeof rows;
        let bytes = 0;
        for (const row of rows.slice(0, 500)) {
          const size = new TextEncoder().encode(JSON.stringify(row)).length;
          if (page.length && bytes + size > 6 * 1024 * 1024) break;
          page.push(row);
          bytes += size;
        }
        for (const segment of page) {
          digest.add(segment.segmentId.toLowerCase(), false);
          digest.add(segment.text);
          count += 1;
        }
        const last = page.at(-1);
        nextCursor = rows.length > page.length && last ? `${last.startTime.toISOString()},${last.segmentId}` : null;
        cursor = nextCursor && last ? { startTime: last.startTime, segmentId: last.segmentId } : undefined;
        if (!manifestOnly) { items = page; break; }
      } while (cursor);
    }
  }
  return { version: TEXT_CONTENT_VERSION, entity, entityId, revision, present, count,
    byteCount: digest.byteCount, sha256: digest.digestHex(),
    ...(!manifestOnly ? { record, items, nextCursor } : {}) };
}

function assertRevision(actual: number, expected: number) {
  if (actual !== expected) throw new SyncTransactionError(409, "content_revision_changed");
}

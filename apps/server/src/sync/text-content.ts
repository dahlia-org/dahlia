import { IncrementalSha256 } from "../storage/sha256";
import type { IdentitySyncStore, SyncCanonicalRecord, SyncTranscriptCursor } from "./types";
import { SyncTransactionError } from "./store";

export const TEXT_CONTENT_VERSION = 1;
export type TextEntity = "summary" | "transcript";

/** Each nullable UTF-8 field is framed by its decimal byte length and ':'. Null is '-:'.
 * Transcript fields are segment UUID (lowercase), text, in (startedAt, UUID) order.
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

export function fileTextMetadata(record: Record<string, unknown>): Record<string, unknown> {
  const metadata = { ...(record.metadata ?? {}) as Record<string, unknown> };
  delete metadata.ocr_text;
  delete metadata.caption;
  return { ...record, metadata, contentOmitted: true, contentPresent: true };
}

export function meetingMetadata(record: Record<string, unknown>): Record<string, unknown> {
  // Only meeting metadata crosses the sync feed.
  const keys = ["meetingId", "vaultId", "projectId", "name", "description", "status", "duration",
    "recordingStartedAt", "isRecording", "createdAt", "updatedAt", "revision", "summaryRevision", "transcriptRevision", "active", "deletingAt"];
  const hasSummary = record.hasSummary ?? (record.summaryDocument !== null && record.summaryDocument !== undefined);
  return { ...Object.fromEntries(keys.filter((key) => key in record).map((key) => [key, record[key]])), contentOmitted: true, hasSummary };
}

export async function metadataRecord(value: SyncCanonicalRecord, store: IdentitySyncStore, vaultId: string): Promise<SyncCanonicalRecord> {
  if (!value.record) return value;
  let record: Record<string, unknown> = { ...value.record };
  if (value.entity === "meeting") {
    record = meetingMetadata(record);
  } else if (value.entity === "summary") {
    record = { id: record.id, version: record.version, meetingId: record.meetingId, title: record.title, createdAt: record.createdAt,
      contentOmitted: true, contentPresent: record.document !== null && record.document !== undefined };
  } else if (value.entity === "transcript") {
    record = { meetingId: record.meetingId, contentOmitted: true, contentPresent: true,
      contentCount: await store.countTranscript(vaultId, value.id), transcript: record.transcript };
  } else if (value.entity === "file") {
    record = fileTextMetadata(record);
  }
  return { ...value, record };
}

/** The caller holds the Vault lock within its identity transaction, including every revision check. */
export async function readTextContent(
  store: IdentitySyncStore, vaultId: string, entity: TextEntity, entityId: string,
  revision: number, manifestOnly: boolean, after?: SyncTranscriptCursor, transcriptVersion?: number,
) {
  const digest = new TextContentDigest();
  let count = 0;
  let present: boolean;
  let record: Record<string, unknown> | undefined;
  let items: Awaited<ReturnType<IdentitySyncStore["listTranscript"]>> | undefined;
  let nextCursor: string | null = null;
  if (!await store.getVault(vaultId)) throw new SyncTransactionError(404, "vault_not_found");
  const meeting = await store.getMeeting(vaultId, entityId);
  if (!meeting) throw new SyncTransactionError(404, "meeting_not_found");
  const transcript = entity === "transcript" ? await store.getTranscript(vaultId, entityId, transcriptVersion) : null;
  if (transcriptVersion !== undefined && !transcript) throw new SyncTransactionError(404, "transcript_version_not_found");
  if (transcriptVersion === undefined) assertRevision((entity === "summary" ? meeting.summaryRevision : meeting.transcriptRevision) ?? 0, revision);
  const summary = entity === "summary" ? await store.getSummaryVersion(vaultId, entityId) : null;
  if (entity === "summary") {
    present = summary !== null;
    digest.add(summary?.document ?? null);
    count = present ? 1 : 0;
    record = summary ? { ...summary } : { title: null, document: null, createdAt: null };
  } else {
    present = transcript !== null;
    let cursor = after;
    do {
      const rows = await store.listTranscript(vaultId, entityId, 501, cursor, transcript?.version);
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
      nextCursor = rows.length > page.length && last ? `${last.startedAt.toISOString()},${last.segmentId}` : null;
      cursor = nextCursor && last ? { startedAt: last.startedAt, segmentId: last.segmentId } : undefined;
      if (!manifestOnly) { items = page; break; }
    } while (cursor);
  }
  return { ...(entity === "transcript"
    ? { formatVersion: TEXT_CONTENT_VERSION, version: transcript?.version ?? 0, syncRevision: transcript?.syncRevision ?? revision, transcript }
    : { formatVersion: TEXT_CONTENT_VERSION, version: summary?.version ?? 0, revision }), entity, entityId, present, count,
    byteCount: digest.byteCount, sha256: digest.digestHex(),
    ...(!manifestOnly ? { record, items, nextCursor } : {}) };
}

function assertRevision(actual: number, expected: number) {
  if (actual !== expected) throw new SyncTransactionError(409, "content_revision_changed");
}

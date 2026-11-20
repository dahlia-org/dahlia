// The app's own SQLite database (node:sqlite). Nothing here is shared with Dahlia for macOS or the alpha.
import { randomUUID } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import type { AudioSource, Meeting, MeetingSummary, Recording, RecordingStatus, Settings, SummaryDocument, SummaryState, TranscriptSegment } from "../shared/types.js";

const migrations = [
  `CREATE TABLE meetings (
     id TEXT PRIMARY KEY,
     name TEXT NOT NULL,
     name_edited INTEGER NOT NULL DEFAULT 0,
     description TEXT NOT NULL DEFAULT '',
     created_at INTEGER NOT NULL,
     updated_at INTEGER NOT NULL
   );
   CREATE TABLE recordings (
     id TEXT PRIMARY KEY,
     meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
     started_at INTEGER NOT NULL,
     ended_at INTEGER,
     duration_ms INTEGER NOT NULL DEFAULT 0,
     offset_ms INTEGER NOT NULL,
     locale TEXT NOT NULL,
     status TEXT NOT NULL,
     error TEXT
   );
   CREATE INDEX recordings_meeting ON recordings(meeting_id, started_at);
   CREATE TABLE transcript_segments (
     id TEXT PRIMARY KEY,
     meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
     recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
     source TEXT NOT NULL,
     start_ms INTEGER NOT NULL,
     end_ms INTEGER NOT NULL,
     text TEXT NOT NULL
   );
   CREATE INDEX transcript_segments_recording ON transcript_segments(recording_id, start_ms);
   CREATE TABLE summaries (
     meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
     document TEXT,
     model TEXT,
     status TEXT NOT NULL,
     error TEXT,
     created_at INTEGER NOT NULL
   );
   CREATE TABLE settings (
     key TEXT PRIMARY KEY,
     value TEXT NOT NULL
   );`,
];

export const defaultSettings: Settings = { transcriptionLocale: "ja-JP", summaryLanguage: "ja", summaryModel: "system.ai.claude-haiku-5-5" };

type Row = Record<string, string | number | null>;
const text = (value: unknown) => (typeof value === "string" ? value : "");

export class Database {
  private readonly db: DatabaseSync;

  constructor(file: string) {
    this.db = new DatabaseSync(file);
    this.db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA synchronous = FULL;");
    const { user_version: version } = this.db.prepare("PRAGMA user_version").get() as { user_version: number };
    for (let index = version; index < migrations.length; index++) {
      this.transaction(() => {
        this.db.exec(migrations[index]!);
        this.db.exec(`PRAGMA user_version = ${index + 1}`);
      });
    }
  }

  close() {
    this.db.close();
  }

  private transaction<T>(work: () => T): T {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const result = work();
      this.db.exec("COMMIT");
      return result;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  listMeetings(): MeetingSummary[] {
    return (this.db.prepare(
      `SELECT m.id, m.name, m.created_at,
              EXISTS(SELECT 1 FROM recordings r WHERE r.meeting_id = m.id AND r.status IN ('recording', 'recorded', 'transcribing')) AS busy
         FROM meetings m ORDER BY m.created_at DESC`,
    ).all() as Row[]).map((row) => ({ id: text(row.id), name: text(row.name), createdAt: Number(row.created_at), busy: Boolean(row.busy) }));
  }

  createMeeting(name: string, now = Date.now()): string {
    const id = randomUUID();
    this.db.prepare("INSERT INTO meetings (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)").run(id, name, now, now);
    return id;
  }

  getMeeting(id: string): Meeting | undefined {
    const row = this.db.prepare("SELECT * FROM meetings WHERE id = ?").get(id) as Row | undefined;
    if (!row) return undefined;
    const recordings = (this.db.prepare("SELECT * FROM recordings WHERE meeting_id = ? ORDER BY started_at").all(id) as Row[]).map(recording);
    const segments = (this.db.prepare(
      `SELECT s.*, r.offset_ms FROM transcript_segments s JOIN recordings r ON r.id = s.recording_id
        WHERE s.meeting_id = ? ORDER BY r.started_at, s.start_ms, s.source`,
    ).all(id) as Row[]).map(segment);
    const summaryRow = this.db.prepare("SELECT * FROM summaries WHERE meeting_id = ?").get(id) as Row | undefined;
    return {
      id,
      name: text(row.name),
      description: text(row.description),
      createdAt: Number(row.created_at),
      recordings,
      segments,
      summary: summaryRow ? summary(summaryRow) : undefined,
    };
  }

  renameMeeting(id: string, name: string) {
    this.db.prepare("UPDATE meetings SET name = ?, name_edited = 1, updated_at = ? WHERE id = ?").run(name, Date.now(), id);
  }

  deleteMeeting(id: string) {
    this.db.prepare("DELETE FROM meetings WHERE id = ?").run(id);
  }

  /** Starts a recording after the meeting's earlier ones, so transcript times read as one timeline. */
  startRecording(meetingId: string, locale: string, now = Date.now()): Recording {
    return this.transaction(() => {
      const { offset } = this.db.prepare("SELECT COALESCE(SUM(duration_ms), 0) AS offset FROM recordings WHERE meeting_id = ?").get(meetingId) as { offset: number };
      const id = randomUUID();
      this.db.prepare(
        "INSERT INTO recordings (id, meeting_id, started_at, offset_ms, locale, status) VALUES (?, ?, ?, ?, ?, 'recording')",
      ).run(id, meetingId, now, offset, locale);
      this.db.prepare("UPDATE meetings SET updated_at = ? WHERE id = ?").run(now, meetingId);
      return this.recording(id)!;
    });
  }

  recording(id: string): Recording | undefined {
    const row = this.db.prepare("SELECT * FROM recordings WHERE id = ?").get(id) as Row | undefined;
    return row ? recording(row) : undefined;
  }

  recordingsWithStatus(...statuses: RecordingStatus[]): Recording[] {
    return (this.db.prepare(`SELECT * FROM recordings WHERE status IN (${statuses.map(() => "?").join(", ")}) ORDER BY started_at`)
      .all(...statuses) as Row[]).map(recording);
  }

  finishRecording(id: string, durationMs: number, endedAt = Date.now()) {
    this.db.prepare("UPDATE recordings SET status = 'recorded', duration_ms = ?, ended_at = ?, error = NULL WHERE id = ?").run(durationMs, endedAt, id);
  }

  deleteRecording(id: string) {
    this.db.prepare("DELETE FROM recordings WHERE id = ?").run(id);
  }

  setRecordingStatus(id: string, status: RecordingStatus, error: string | null = null) {
    this.db.prepare("UPDATE recordings SET status = ?, error = ? WHERE id = ?").run(status, error, id);
  }

  /** Replaces the recording's whole transcript at once; a failed run never leaves part of one. */
  replaceTranscript(recordingId: string, segments: Omit<TranscriptSegment, "id" | "offsetMs" | "recordingId">[]) {
    this.transaction(() => {
      const { meeting_id: meetingId } = this.db.prepare("SELECT meeting_id FROM recordings WHERE id = ?").get(recordingId) as { meeting_id: string };
      this.db.prepare("DELETE FROM transcript_segments WHERE recording_id = ?").run(recordingId);
      const insert = this.db.prepare(
        "INSERT INTO transcript_segments (id, meeting_id, recording_id, source, start_ms, end_ms, text) VALUES (?, ?, ?, ?, ?, ?, ?)",
      );
      for (const item of segments) insert.run(randomUUID(), meetingId, recordingId, item.source, item.startMs, item.endMs, item.text);
      this.db.prepare("UPDATE recordings SET status = 'transcribed', error = NULL WHERE id = ?").run(recordingId);
    });
  }

  setSummaryState(meetingId: string, status: "generating" | "failed", error: string | null = null) {
    this.db.prepare(
      `INSERT INTO summaries (meeting_id, status, error, created_at) VALUES (?, ?, ?, ?)
       ON CONFLICT(meeting_id) DO UPDATE SET status = excluded.status, error = excluded.error`,
    ).run(meetingId, status, error, Date.now());
  }

  /** Saves the summary and takes its title and description, unless the user named the meeting. */
  saveSummary(meetingId: string, document: SummaryDocument, model: string, now = Date.now()) {
    this.transaction(() => {
      this.db.prepare(
        `INSERT INTO summaries (meeting_id, document, model, status, error, created_at) VALUES (?, ?, ?, 'ready', NULL, ?)
         ON CONFLICT(meeting_id) DO UPDATE SET document = excluded.document, model = excluded.model, status = 'ready', error = NULL, created_at = excluded.created_at`,
      ).run(meetingId, JSON.stringify(document), model, now);
      if (document.title.trim()) {
        this.db.prepare("UPDATE meetings SET name = ? WHERE id = ? AND name_edited = 0").run(document.title.trim(), meetingId);
      }
      if (document.description.trim()) {
        this.db.prepare("UPDATE meetings SET description = ? WHERE id = ?").run(document.description.trim(), meetingId);
      }
      this.db.prepare("UPDATE meetings SET updated_at = ? WHERE id = ?").run(now, meetingId);
    });
  }

  /** Summaries that were generating when the app last quit. */
  interruptSummaries(message: string) {
    this.db.prepare("UPDATE summaries SET status = 'failed', error = ? WHERE status = 'generating'").run(message);
  }

  settings(): Settings {
    const values = Object.fromEntries((this.db.prepare("SELECT key, value FROM settings").all() as Row[]).map((row) => [text(row.key), text(row.value)]));
    return {
      transcriptionLocale: values.transcriptionLocale || defaultSettings.transcriptionLocale,
      summaryLanguage: values.summaryLanguage || defaultSettings.summaryLanguage,
      summaryModel: values.summaryModel || defaultSettings.summaryModel,
    };
  }

  setSetting(key: keyof Settings, value: string) {
    this.db.prepare("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(key, value);
  }
}

function recording(row: Row): Recording {
  return {
    id: text(row.id),
    meetingId: text(row.meeting_id),
    startedAt: Number(row.started_at),
    endedAt: row.ended_at === null ? undefined : Number(row.ended_at),
    durationMs: Number(row.duration_ms),
    offsetMs: Number(row.offset_ms),
    locale: text(row.locale),
    status: text(row.status) as RecordingStatus,
    error: row.error === null ? undefined : text(row.error),
  };
}

function segment(row: Row): TranscriptSegment {
  return {
    id: text(row.id),
    recordingId: text(row.recording_id),
    source: text(row.source) as AudioSource,
    startMs: Number(row.start_ms),
    endMs: Number(row.end_ms),
    offsetMs: Number(row.offset_ms),
    text: text(row.text),
  };
}

function summary(row: Row): SummaryState {
  return {
    status: text(row.status) as SummaryState["status"],
    document: typeof row.document === "string" ? (JSON.parse(row.document) as SummaryDocument) : undefined,
    model: row.model === null ? undefined : text(row.model),
    error: row.error === null ? undefined : text(row.error),
    createdAt: Number(row.created_at),
  };
}

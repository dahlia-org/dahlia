// The processing queue after a recording: transcription on the Mac, then the summary. One job at a time; the stored
// statuses are the truth, so a quit mid-job is resumed (transcription) or shown as interrupted (summary) on next launch.
import { rmSync } from "node:fs";
import { audioSources, type Progress } from "../shared/types.js";
import type { Database } from "./db.js";
import { SignInError } from "./oauth.js";
import { recordingDirectory, recoveredDurationMs } from "./recorder.js";
import { generateSummary, SummaryError } from "./summary.js";
import { transcribeRecording, TranscriptionError } from "./transcriber.js";

export type ProcessorDependencies = {
  db: Database;
  recordingsRoot: string;
  helper: string;
  token: () => Promise<{ workspace: string; token: string }>;
  notify: () => void;
  transcribe?: typeof transcribeRecording;
  summarize?: typeof generateSummary;
};

export class Processor {
  private queue: Promise<void> = Promise.resolve();
  private readonly progress = new Map<string, Progress>();
  private readonly controller = new AbortController();
  private readonly transcribe: typeof transcribeRecording;
  private readonly summarize: typeof generateSummary;
  private lastProgressNotice = 0;

  constructor(private readonly deps: ProcessorDependencies) {
    this.transcribe = deps.transcribe ?? transcribeRecording;
    this.summarize = deps.summarize ?? generateSummary;
  }

  /** Brings back what the last run left: open recordings are closed from their files, unfinished ones requeued. */
  recover() {
    const { db } = this.deps;
    for (const recording of db.recordingsWithStatus("recording")) {
      const directory = recordingDirectory(this.deps.recordingsRoot, recording.meetingId, recording.id);
      let durationMs: number;
      try {
        durationMs = recoveredDurationMs(directory);
      } catch {
        db.setRecordingStatus(recording.id, "failed", "writeFailed");
        continue;
      }
      if (durationMs > 0) {
        db.finishRecording(recording.id, durationMs);
      } else {
        // Stopped before any audio arrived: nothing to keep, as when a recording stops empty.
        rmSync(directory, { recursive: true, force: true });
        db.deleteRecording(recording.id);
      }
    }
    for (const recording of db.recordingsWithStatus("transcribing")) db.setRecordingStatus(recording.id, "recorded");
    db.interruptSummaries("interrupted");
    for (const recording of db.recordingsWithStatus("recorded")) this.enqueueTranscription(recording.id);
  }

  progressList() {
    return [...this.progress.values()];
  }

  /** Whether the meeting has work queued or running, which blocks deleting it. */
  isBusy(meetingId: string) {
    const meeting = this.deps.db.getMeeting(meetingId);
    return Boolean(meeting && (meeting.recordings.some((recording) => ["recording", "recorded", "transcribing"].includes(recording.status))
      || meeting.summary?.status === "generating"));
  }

  /** Waits for the queue; for tests. */
  idle() {
    return this.queue;
  }

  stop() {
    this.controller.abort();
  }

  enqueueTranscription(recordingId: string) {
    this.enqueue(() => this.runTranscription(recordingId));
  }

  /** Transcribes the meeting's finished recordings again, then summarizes. Earlier transcripts stay until each succeeds. */
  retranscribe(meetingId: string) {
    const meeting = this.deps.db.getMeeting(meetingId);
    if (!meeting) return;
    for (const recording of meeting.recordings) {
      if (recording.status === "transcribed" || recording.status === "failed") {
        this.deps.db.setRecordingStatus(recording.id, "recorded");
        this.enqueueTranscription(recording.id);
      }
    }
    this.deps.notify();
  }

  enqueueSummary(meetingId: string) {
    // Shown as generating while it waits, so the button cannot queue it twice.
    this.deps.db.setSummaryState(meetingId, "generating");
    this.deps.notify();
    this.enqueue(() => this.runSummary(meetingId));
  }

  private enqueue(job: () => Promise<void>) {
    this.queue = this.queue.then(job).catch(() => {
      // Each job stores its own failure; nothing reaches here but a deleted meeting.
    });
  }

  private async runTranscription(recordingId: string) {
    const { db } = this.deps;
    const recording = db.recording(recordingId);
    if (!recording || recording.status !== "recorded" || this.controller.signal.aborted) return;
    db.setRecordingStatus(recordingId, "transcribing");
    this.progress.set(recording.meetingId, { meetingId: recording.meetingId, step: "transcribing", fraction: 0 });
    this.deps.notify();
    try {
      const segments = await this.transcribe(
        this.deps.helper,
        recordingDirectory(this.deps.recordingsRoot, recording.meetingId, recordingId),
        recording.locale,
        (update) => {
          const index = audioSources.indexOf(update.source);
          this.progress.set(recording.meetingId, update.type === "asset"
            ? { meetingId: recording.meetingId, step: "transcribing", fraction: update.fraction, detail: "downloadingModel" }
            : { meetingId: recording.meetingId, step: "transcribing", fraction: (index + Math.min(1, update.processedMs / Math.max(1, recording.durationMs))) / audioSources.length });
          // The helper reports every few seconds of audio, far faster than real time; each notice reloads the window.
          if (Date.now() - this.lastProgressNotice >= 500) {
            this.lastProgressNotice = Date.now();
            this.deps.notify();
          }
        },
        this.controller.signal,
      );
      db.replaceTranscript(recordingId, segments);
    } catch (error) {
      // A quit leaves it transcribing, so the next launch starts it again.
      if (!this.controller.signal.aborted && db.recording(recordingId)) {
        db.setRecordingStatus(recordingId, "failed", error instanceof TranscriptionError ? error.code : "failed");
      }
      return;
    } finally {
      this.progress.delete(recording.meetingId);
      this.deps.notify();
    }
    const pending = db.getMeeting(recording.meetingId)?.recordings.some((item) => ["recording", "recorded", "transcribing"].includes(item.status));
    if (!pending) this.enqueueSummary(recording.meetingId);
  }

  private async runSummary(meetingId: string) {
    const { db } = this.deps;
    const meeting = db.getMeeting(meetingId);
    if (!meeting || this.controller.signal.aborted) return;
    const settings = db.settings();
    this.progress.set(meetingId, { meetingId, step: "summarizing" });
    this.deps.notify();
    try {
      const { workspace, token } = await this.deps.token();
      const document = await this.summarize({
        workspace, token, model: settings.summaryModel, language: settings.summaryLanguage, segments: meeting.segments, signal: this.controller.signal,
      });
      if (db.getMeeting(meetingId)) db.saveSummary(meetingId, document, settings.summaryModel);
    } catch (error) {
      if (!this.controller.signal.aborted && db.getMeeting(meetingId)) {
        db.setSummaryState(meetingId, "failed", error instanceof SummaryError ? error.code : error instanceof SignInError ? `auth_${error.message}` : "failed");
      }
    } finally {
      this.progress.delete(meetingId);
      this.deps.notify();
    }
  }
}

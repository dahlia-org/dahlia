import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { Database } from "../src/main/db.js";
import { SignInError } from "../src/main/oauth.js";
import { Processor, type ProcessorDependencies } from "../src/main/processing.js";
import { audioFile, recordingDirectory, recoveredDurationMs } from "../src/main/recorder.js";
import { TranscriptionError } from "../src/main/transcriber.js";
import type { SummaryDocument } from "../src/shared/types.js";

const document: SummaryDocument = { title: "T", description: "D", sections: [{ heading: "", blocks: [{ type: "paragraph", text: "x", transcript_ref: null }] }], action_items: [] };

vi.mock("../src/main/recorder.js", async (original) => {
  const recorder = await original<typeof import("../src/main/recorder.js")>();
  return { ...recorder, recoveredDurationMs: vi.fn(recorder.recoveredDurationMs) };
});

function setup(overrides: Partial<ProcessorDependencies> = {}) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-v2-proc-"));
  const db = new Database(join(directory, "db.sqlite"));
  const recordingsRoot = join(directory, "recordings");
  const transcribe = vi.fn<NonNullable<ProcessorDependencies["transcribe"]>>(async () => [{ source: "mic", startMs: 0, endMs: 1000, text: "hello" }]);
  const summarize = vi.fn<NonNullable<ProcessorDependencies["summarize"]>>(async () => document);
  const processor = new Processor({
    db, recordingsRoot, helper: "/helper", token: async () => ({ workspace: "https://w.example.com", token: "t" }), notify: () => {}, transcribe, summarize, ...overrides,
  });
  return { db, processor, recordingsRoot, transcribe, summarize };
}

describe("Processor", () => {
  it("transcribes a finished recording, then summarizes the meeting", async () => {
    const { db, processor, transcribe, summarize } = setup();
    const meeting = db.createMeeting("M");
    const recording = db.startRecording(meeting, "en-US");
    db.finishRecording(recording.id, 5000);
    processor.enqueueTranscription(recording.id);
    await processor.idle();
    await processor.idle();
    expect(transcribe).toHaveBeenCalledWith("/helper", expect.stringContaining(recording.id), "en-US", expect.any(Function), expect.any(AbortSignal));
    expect(summarize).toHaveBeenCalledWith(expect.objectContaining({ model: "system.ai.claude-haiku-5-5", language: "ja", segments: [expect.objectContaining({ text: "hello" })] }));
    expect(db.getMeeting(meeting)).toMatchObject({ name: "T", summary: { status: "ready", document } });
  });

  it("records a failed transcription and does not summarize", async () => {
    const { db, processor, summarize } = setup({ transcribe: async () => { throw new TranscriptionError("assets_unavailable"); } });
    const meeting = db.createMeeting("M");
    const recording = db.startRecording(meeting, "ja-JP");
    db.finishRecording(recording.id, 1000);
    processor.enqueueTranscription(recording.id);
    await processor.idle();
    expect(db.recording(recording.id)).toMatchObject({ status: "failed", error: "assets_unavailable" });
    expect(summarize).not.toHaveBeenCalled();
  });

  it("records a summary that needs sign-in, keeping the transcript", async () => {
    const { db, processor } = setup({ token: async () => { throw new SignInError("signedOut"); } });
    const meeting = db.createMeeting("M");
    const recording = db.startRecording(meeting, "ja-JP");
    db.finishRecording(recording.id, 1000);
    processor.enqueueTranscription(recording.id);
    await processor.idle();
    await processor.idle();
    expect(db.getMeeting(meeting)).toMatchObject({ summary: { status: "failed", error: "auth_signedOut" }, segments: [expect.objectContaining({ text: "hello" })] });
  });

  it("waits for every recording of the meeting before summarizing", async () => {
    const { db, processor, summarize } = setup();
    const meeting = db.createMeeting("M");
    const first = db.startRecording(meeting, "ja-JP");
    db.finishRecording(first.id, 1000);
    const second = db.startRecording(meeting, "ja-JP");
    db.finishRecording(second.id, 1000);
    processor.enqueueTranscription(first.id);
    processor.enqueueTranscription(second.id);
    for (let index = 0; index < 4; index++) await processor.idle();
    expect(summarize).toHaveBeenCalledTimes(1);
  });

  it("recovers on launch: closes open recordings from their files, requeues unfinished ones and marks summaries interrupted", async () => {
    const { db, processor, recordingsRoot, transcribe } = setup();
    const meeting = db.createMeeting("M");
    const open = db.startRecording(meeting, "ja-JP");
    const directory = recordingDirectory(recordingsRoot, meeting, open.id);
    mkdirSync(directory, { recursive: true });
    writeFileSync(audioFile(directory, "mic"), new Uint8Array(64_000));
    const other = db.createMeeting("N");
    const interrupted = db.startRecording(other, "ja-JP");
    db.finishRecording(interrupted.id, 1000);
    db.setRecordingStatus(interrupted.id, "transcribing");
    const summarized = db.createMeeting("S");
    db.setSummaryState(summarized, "generating");

    processor.recover();
    expect(db.recording(open.id)).toMatchObject({ durationMs: 2000 });
    expect(db.getMeeting(summarized)?.summary).toMatchObject({ status: "failed", error: "interrupted" });
    for (let index = 0; index < 4; index++) await processor.idle();
    expect(transcribe).toHaveBeenCalledTimes(2);
    expect(db.recording(open.id)?.status).toBe("transcribed");
    expect(db.recording(interrupted.id)?.status).toBe("transcribed");
  });

  it("transcribes again on request and leaves the earlier transcript until it succeeds", async () => {
    let fail = false;
    const { db, processor } = setup({ transcribe: async () => { if (fail) throw new TranscriptionError("stalled"); return [{ source: "mic", startMs: 0, endMs: 1, text: "first" }]; } });
    const meeting = db.createMeeting("M");
    const recording = db.startRecording(meeting, "ja-JP");
    db.finishRecording(recording.id, 1000);
    processor.enqueueTranscription(recording.id);
    for (let index = 0; index < 2; index++) await processor.idle();
    fail = true;
    processor.retranscribe(meeting);
    expect(processor.isBusy(meeting)).toBe(true);
    await processor.idle();
    expect(db.getMeeting(meeting)?.segments.map((segment) => segment.text)).toEqual(["first"]);
    expect(db.recording(recording.id)).toMatchObject({ status: "failed", error: "stalled" });
  });
});

describe("Processor.recover", () => {
  it("keeps a recording whose files cannot be inspected", () => {
    const { db, processor } = setup();
    const meeting = db.createMeeting("M");
    const recording = db.startRecording(meeting, "ja-JP");
    vi.mocked(recoveredDurationMs).mockImplementationOnce(() => { throw new Error("EIO"); });
    processor.recover();
    expect(db.recording(recording.id)).toMatchObject({ status: "failed", error: "writeFailed" });
  });
  it("removes a recording that stopped before any audio arrived", () => {
    const { db, processor } = setup();
    const meeting = db.createMeeting("M");
    const empty = db.startRecording(meeting, "ja-JP");
    processor.recover();
    expect(db.recording(empty.id)).toBeUndefined();
  });
});

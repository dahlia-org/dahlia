import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { Database, defaultSettings } from "../src/main/db.js";
import type { SummaryDocument } from "../src/shared/types.js";

const open = () => new Database(join(mkdtempSync(join(tmpdir(), "dahlia-v2-db-")), "test.sqlite"));
const document: SummaryDocument = {
  title: "Generated title",
  description: "Generated description",
  sections: [{ heading: "", blocks: [{ type: "paragraph", text: "Body", transcript_ref: null }] }],
  action_items: [],
};

describe("Database", () => {
  it("migrates once and keeps data across opens", () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-v2-db-"));
    const first = new Database(join(directory, "a.sqlite"));
    const id = first.createMeeting("A");
    first.close();
    const second = new Database(join(directory, "a.sqlite"));
    expect(second.getMeeting(id)?.name).toBe("A");
  });

  it("places each recording after the meeting's earlier ones", () => {
    const db = open();
    const meeting = db.createMeeting("M");
    const first = db.startRecording(meeting, "ja-JP", 1000);
    db.finishRecording(first.id, 60_000);
    const second = db.startRecording(meeting, "ja-JP", 90_000);
    expect(second.offsetMs).toBe(60_000);
    db.replaceTranscript(second.id, [{ source: "system", startMs: 2000, endMs: 3000, text: "later" }]);
    db.replaceTranscript(first.id, [{ source: "mic", startMs: 5000, endMs: 6000, text: "earlier" }]);
    expect(db.getMeeting(meeting)?.segments.map((segment) => [segment.text, segment.offsetMs + segment.startMs])).toEqual([["earlier", 5000], ["later", 62_000]]);
  });

  it("replaces a recording's transcript and marks it transcribed", () => {
    const db = open();
    const meeting = db.createMeeting("M");
    const recording = db.startRecording(meeting, "ja-JP");
    db.finishRecording(recording.id, 1000);
    db.replaceTranscript(recording.id, [{ source: "mic", startMs: 0, endMs: 1, text: "old" }]);
    db.replaceTranscript(recording.id, [{ source: "mic", startMs: 0, endMs: 1, text: "new" }]);
    expect(db.getMeeting(meeting)?.segments.map((segment) => segment.text)).toEqual(["new"]);
    expect(db.recording(recording.id)?.status).toBe("transcribed");
  });

  it("takes the summary's title only while the user has not renamed the meeting", () => {
    const db = open();
    const automatic = db.createMeeting("Default");
    const renamed = db.createMeeting("Default");
    db.renameMeeting(renamed, "Mine");
    db.saveSummary(automatic, document, "model");
    db.saveSummary(renamed, document, "model");
    expect(db.getMeeting(automatic)).toMatchObject({ name: "Generated title", description: "Generated description" });
    expect(db.getMeeting(renamed)).toMatchObject({ name: "Mine", description: "Generated description" });
  });

  it("keeps the last summary while a new one generates or fails", () => {
    const db = open();
    const meeting = db.createMeeting("M");
    db.saveSummary(meeting, document, "model");
    db.setSummaryState(meeting, "generating");
    db.setSummaryState(meeting, "failed", "network");
    expect(db.getMeeting(meeting)?.summary).toMatchObject({ status: "failed", error: "network", document });
    db.interruptSummaries("interrupted");
    db.setSummaryState(meeting, "generating");
    db.interruptSummaries("interrupted");
    expect(db.getMeeting(meeting)?.summary).toMatchObject({ status: "failed", error: "interrupted" });
  });

  it("deletes a meeting with its recordings, transcript and summary", () => {
    const db = open();
    const meeting = db.createMeeting("M");
    const recording = db.startRecording(meeting, "ja-JP");
    db.replaceTranscript(recording.id, [{ source: "mic", startMs: 0, endMs: 1, text: "x" }]);
    db.saveSummary(meeting, document, "model");
    db.deleteMeeting(meeting);
    expect(db.getMeeting(meeting)).toBeUndefined();
    expect(db.recording(recording.id)).toBeUndefined();
  });

  it("reads settings with defaults", () => {
    const db = open();
    expect(db.settings()).toEqual(defaultSettings);
    db.setSetting("summaryLanguage", "en");
    expect(db.settings().summaryLanguage).toBe("en");
  });
});

import { afterEach, expect, it, vi } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { readTranscriptPages, TranscriptHistory } from "../src/client/TranscriptHistory";
import * as liveData from "../src/client/live-data";

afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

it.each([
  ["2026-09-09T00:00:00Z", null, "Generation ended"],
  [null, "2026-09-09T00:00:00Z", "Recent generation activity"],
  [null, "2026-09-08T23:54:59Z", "No recent generation activity"],
  [null, null, "Activity unknown"],
])("renders speaker badges without activity status for endedAt=%s and latestSegmentCreatedAt=%s", (endedAt, latestSegmentCreatedAt, label) => {
  vi.stubGlobal("navigator", { language: "en" });
  vi.spyOn(Date, "now").mockReturnValue(Date.parse("2026-09-09T00:00:00Z"));
  const query = { data: { transcript: { endedAt, latestSegmentCreatedAt }, items: [{ segmentId: "sample", startedAt: "2026-09-09T00:00:00Z", speakerLabel: "Participant A", text: "Preview transcript" }] },
    error: undefined, loading: false, reload: vi.fn(), replace: vi.fn() };
  vi.spyOn(liveData, "useLiveQuery").mockReturnValue(query);
  vi.spyOn(liveData, "useLivePage").mockReturnValue({ ...query, loadingMore: false, loadMore: vi.fn() });
  const html = renderToStaticMarkup(createElement(TranscriptHistory, { meetingId: "meeting", timeBase: "2026-09-09T00:00:00Z" }));
  expect(html).not.toContain(label);
  expect(html).toContain('<span class="transcript-speaker">Participant A</span>Preview transcript');
});

it("retains the visible page depth and rejects mixed versions during refresh", async () => {
  const signal = new AbortController().signal;
  const page = { version: 2, syncRevision: 7, transcript: null,
    items: [{ segmentId: "one", text: "retained" }], nextCursor: "page2" };
  const fetch = vi.fn().mockResolvedValueOnce(Response.json(page))
    .mockResolvedValueOnce(Response.json({ ...page, items: [{ segmentId: "two", text: "next" }], nextCursor: null }));
  vi.stubGlobal("fetch", fetch);
  expect((await readTranscriptPages(liveData.apiQuery("getTranscript", { params: { path: { meetingId: "meeting", version: "2" } } }), 2, signal)).items).toHaveLength(2);
  expect(new URL((fetch.mock.calls[1]?.[0] as Request).url).pathname).toBe("/api/v1/meetings/meeting/transcripts/2");
  fetch.mockResolvedValueOnce(Response.json(page)).mockResolvedValueOnce(Response.json({ ...page, syncRevision: 8 }));
  await expect(readTranscriptPages(liveData.apiQuery("getLatestTranscript", { params: { path: { meetingId: "meeting" } } }), 2, signal)).rejects.toThrow();
});

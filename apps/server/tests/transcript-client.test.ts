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
])("renders activity for endedAt=%s and latestSegmentCreatedAt=%s", (endedAt, latestSegmentCreatedAt, label) => {
  vi.stubGlobal("navigator", { language: "en" });
  vi.spyOn(Date, "now").mockReturnValue(Date.parse("2026-09-09T00:00:00Z"));
  const query = { data: { transcript: { endedAt, latestSegmentCreatedAt }, items: [] },
    error: undefined, loading: false, reload: vi.fn(), replace: vi.fn() };
  vi.spyOn(liveData, "useLiveQuery").mockReturnValue(query);
  vi.spyOn(liveData, "useLivePage").mockReturnValue({ ...query, loadingMore: false, loadMore: vi.fn() });
  expect(renderToStaticMarkup(createElement(TranscriptHistory, { base: "/meeting", timeBase: "2026-09-09T00:00:00Z" })))
    .toContain(`>${label}</span>`);
});

it("retains the visible page depth and rejects mixed versions during refresh", async () => {
  const signal = new AbortController().signal;
  const page = { version: 2, syncRevision: 7, transcript: null,
    items: [{ segmentId: "one", text: "retained" }], nextCursor: "page2" };
  const fetch = vi.fn().mockResolvedValueOnce(Response.json(page))
    .mockResolvedValueOnce(Response.json({ ...page, items: [{ segmentId: "two", text: "next" }], nextCursor: null }));
  vi.stubGlobal("fetch", fetch);
  expect((await readTranscriptPages("/transcript/2", 2, signal)).items).toHaveLength(2);
  expect(fetch.mock.calls[1]?.[0]).toBe("/transcript/2?cursor=page2");
  fetch.mockResolvedValueOnce(Response.json(page)).mockResolvedValueOnce(Response.json({ ...page, syncRevision: 8 }));
  await expect(readTranscriptPages("/transcript/latest", 2, signal)).rejects.toThrow();
});

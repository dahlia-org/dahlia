import { describe, expect, it } from "vitest";
import type { ScreenshotAssessment } from "../src/image-analysis/model";
import { selectSummaryScreenshots } from "../src/summary/screenshot-selection";
import type { SyncScreenshotRecord } from "../src/sync/types";

const screenshot = (index: number, hash = String(index)): SyncScreenshotRecord => ({
  fileId: `file-${index}`, screenshotId: `shot-${index}`, workspaceId: "workspace", meetingId: "meeting",
  capturedAt: new Date(index * 30_000), contentType: "image/webp", storageKey: "unused", contentLength: 1,
  contentHash: hash.padStart(64, "0"), ocrText: null, caption: null,
});
const assessment = (index: number, informative: boolean, duplicateOf?: number): ScreenshotAssessment => ({
  fileId: `file-${index}`, informative, reason: null, duplicateOfFileId: duplicateOf === undefined ? null : `file-${duplicateOf}`,
});
const ids = (images: SyncScreenshotRecord[]) => images.map((image) => image.fileId);

describe("summary screenshot selection", () => {
  it("drops uninformative screenshots and unchanged periodic captures but keeps unassessed ones", () => {
    const images = [0, 1, 2, 3, 4].map((index) => screenshot(index));
    expect(ids(selectSummaryScreenshots(images, [
      assessment(0, false), assessment(1, true), assessment(2, true, 1), assessment(3, true, 2),
    ]))).toEqual(["file-1", "file-4"]);
  });

  it("keeps a duplicate whose original is no longer attached to the meeting", () => {
    expect(ids(selectSummaryScreenshots([screenshot(1)], [assessment(1, true, 0)]))).toEqual(["file-1"]);
  });

  it("drops identical images shown again later", () => {
    expect(ids(selectSummaryScreenshots([screenshot(0, "a"), screenshot(1, "b"), screenshot(2, "a")], []))).toEqual(["file-0", "file-1"]);
  });

  it("samples the remaining screenshots evenly in capture order", () => {
    const images = Array.from({ length: 30 }, (_, index) => screenshot(index));
    const excluded = Array.from({ length: 5 }, (_, index) => assessment(index, false));
    const selected = selectSummaryScreenshots(images, excluded);
    expect(selected).toHaveLength(13);
    expect(ids(selected)).toEqual(Array.from({ length: 13 }, (_, index) => `file-${5 + index * 2}`));
    expect(selectSummaryScreenshots(images, [], 4)).toHaveLength(4);
  });
});

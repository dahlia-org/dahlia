import { describe, expect, it, vi } from "vitest";
import { loadConfig } from "../src/config";
import type { ScreenshotAssessment } from "../src/image-analysis/model";
import { createScreenshotSelector, sampleEvenly, selectSummaryScreenshots, summaryScreenshotCandidates, type ScreenshotSelector } from "../src/summary/screenshot-selection";
import type { SyncScreenshotRecord } from "../src/sync/types";

const screenshot = (index: number, hash = String(index)): SyncScreenshotRecord => ({
  fileId: `file-${index}`, screenshotId: `shot-${index}`, workspaceId: "workspace", meetingId: "meeting",
  capturedAt: new Date(index * 30_000), contentType: "image/webp", storageKey: "unused", contentLength: 1,
  contentHash: hash.padStart(64, "0"), ocrText: "never sent", caption: "never sent",
});
const assessment = (index: number, informative: boolean): ScreenshotAssessment => ({ fileId: `file-${index}`, informative, reason: null });
const ids = (images: SyncScreenshotRecord[]) => images.map((image) => image.fileId);
const signal = () => new AbortController().signal;
const environment = { DAHLIA_AUTH_SECRET: "test-better-auth-secret-at-least-32-characters",
  DAHLIA_AUTH_TYPE: "header", DAHLIA_AI_BACKEND: "databricks",
  DATABRICKS_HOST: "https://workspace.example", DATABRICKS_CLIENT_ID: "client", DATABRICKS_CLIENT_SECRET: "secret",
  DAHLIA_IMAGE_ANALYSIS_MODEL: "system.ai.gpt-5-6-luna",
};

describe("summary screenshot candidates", () => {
  it("drops uninformative and identical screenshots but keeps unassessed ones", () => {
    const images = [screenshot(0), screenshot(1), screenshot(2, "0"), screenshot(3)];
    expect(ids(summaryScreenshotCandidates(images, [assessment(1, false), assessment(3, true)]))).toEqual(["file-0", "file-3"]);
  });

  it("samples evenly in capture order", () => {
    const images = Array.from({ length: 30 }, (_, index) => screenshot(index));
    expect(ids(sampleEvenly(images, 24))).toEqual(Array.from({ length: 15 }, (_, index) => `file-${index * 2}`));
  });
});

describe("summary screenshot preselection", () => {
  it("lets the selector choose among low-resolution candidates without OCR or captions", async () => {
    const images = [0, 1, 2, 3].map((index) => screenshot(index));
    const read = vi.fn(async (image: SyncScreenshotRecord) => new Uint8Array([Number(image.fileId.slice(-1))]));
    const selector: ScreenshotSelector = { select: vi.fn(async (inputs: readonly { data: Uint8Array }[], limit: number) => {
      expect(inputs.map((input) => [...input.data])).toEqual([[0], [1], [2], [3]]);
      expect(limit).toBe(24);
      return [3, 0];
    }) };
    expect(ids(await selectSummaryScreenshots(images, signal(), selector, read))).toEqual(["file-0", "file-3"]);
  });

  it("falls back to even sampling when preselection fails", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const images = [0, 1, 2].map((index) => screenshot(index));
    const selector: ScreenshotSelector = { select: async () => { throw new Error("upstream"); } };
    expect(ids(await selectSummaryScreenshots(images, signal(), selector, async () => new Uint8Array([1]), 2))).toEqual(["file-0", "file-2"]);
    expect(ids(await selectSummaryScreenshots(images, signal(), selector, async () => { throw new Error("missing"); }, 2))).toEqual(["file-0", "file-2"]);
    expect(JSON.stringify(warn.mock.calls)).not.toContain("never sent");
    warn.mockRestore();
    expect(ids(await selectSummaryScreenshots(images, signal(), undefined, undefined, 24))).toEqual(["file-0", "file-1", "file-2"]);
  });

  it("propagates cancellation instead of sampling", async () => {
    const controller = new AbortController();
    const selector: ScreenshotSelector = { select: async () => { controller.abort(); throw new Error("aborted"); } };
    await expect(selectSummaryScreenshots([screenshot(0), screenshot(1)], controller.signal, selector, async () => new Uint8Array([1])))
      .rejects.toBeDefined();
  });

  it("sends only indexed low-resolution images to the image analysis model and validates the indices", async () => {
    let answer = { indices: [2] };
    const transport = vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
      if (String(url).endsWith("/token")) return Response.json({ access_token: "app-token", expires_in: 3600 });
      const body = JSON.parse(String(init?.body)) as { model: string; instructions: string; input: { content: { type: string; text?: string; image_url?: string }[] }[] };
      expect(body.model).toBe("system.ai.gpt-5-6-luna");
      expect(body.instructions).toContain("Select at most 24 images");
      expect(body.input[0]!.content).toEqual([
        { type: "input_text", text: '<image index="1" elapsed_seconds="0"/>' },
        { type: "input_image", image_url: "data:image/webp;base64,AQ==" },
        { type: "input_text", text: '<image index="2" elapsed_seconds="30"/>' },
        { type: "input_image", image_url: "data:image/webp;base64,Ag==" },
      ]);
      return Response.json({ status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify(answer) }] }] });
    });
    const selector = createScreenshotSelector(loadConfig(environment), transport)!;
    const inputs = [{ data: new Uint8Array([1]), capturedAt: new Date(0) }, { data: new Uint8Array([2]), capturedAt: new Date(30_000) }];
    expect(await selector.select(inputs, 24, signal())).toEqual([1]);
    answer = { indices: [3] };
    await expect(selector.select(inputs, 24, signal())).rejects.toThrow("preselection_invalid_response");
    expect(createScreenshotSelector(loadConfig({ ...environment, DAHLIA_IMAGE_ANALYSIS_MODEL: "" }), transport)).toBeUndefined();
  });
});

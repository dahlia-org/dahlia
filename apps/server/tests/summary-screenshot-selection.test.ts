import { describe, expect, it, vi } from "vitest";
import { loadConfig } from "../src/config";
import { createScreenshotSelector, sampleEvenly, selectSummaryScreenshots, summaryScreenshotCandidates, type ScreenshotSelector } from "../src/summary/screenshot-selection";
import type { SyncScreenshotRecord } from "../src/sync/types";

const screenshot = (index: number, hash = String(index)): SyncScreenshotRecord => ({
  fileId: `file-${index}`, screenshotId: `shot-${index}`, workspaceId: "workspace", meetingId: "meeting",
  capturedAt: new Date(index * 30_000), contentType: "image/webp", storageKey: "unused", contentLength: 1,
  contentHash: hash.padStart(64, "0"), ocrText: "never sent", caption: "never sent",
});
const ids = (images: SyncScreenshotRecord[]) => images.map((image) => image.fileId);
const signal = () => new AbortController().signal;
const environment = { DAHLIA_AUTH_SECRET: "test-better-auth-secret-at-least-32-characters",
  DAHLIA_AUTH_TYPE: "header", DAHLIA_AI_BACKEND: "databricks",
  DATABRICKS_HOST: "https://workspace.example", DATABRICKS_CLIENT_ID: "client", DATABRICKS_CLIENT_SECRET: "secret",
  DAHLIA_IMAGE_ANALYSIS_MODEL: "system.ai.gpt-5-6-luna",
};

describe("summary screenshot candidates", () => {
  it("drops screenshots without shared material and identical images", () => {
    const images = [screenshot(0), screenshot(1), screenshot(2, "0"), screenshot(3)];
    expect(ids(summaryScreenshotCandidates(images, ["file-1"]))).toEqual(["file-0", "file-3"]);
  });

  it("samples evenly in capture order", () => {
    const images = Array.from({ length: 30 }, (_, index) => screenshot(index));
    expect(ids(sampleEvenly(images, 24))).toEqual(Array.from({ length: 15 }, (_, index) => `file-${index * 2}`));
  });
});

describe("summary screenshot preselection", () => {
  it("lets the selector choose among low-resolution candidates read concurrently", async () => {
    const images = Array.from({ length: 20 }, (_, index) => screenshot(index));
    let active = 0, peak = 0;
    const read = vi.fn(async (image: SyncScreenshotRecord) => {
      active++; peak = Math.max(peak, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      active--;
      return new Uint8Array([Number(image.fileId.slice(5))]);
    });
    const selector: ScreenshotSelector = { select: vi.fn(async (inputs: readonly { data: Uint8Array }[], limit: number) => {
      expect(inputs.map((input) => input.data[0])).toEqual(Array.from({ length: 20 }, (_, index) => index));
      expect(limit).toBe(24);
      return [19, 0];
    }) };
    const result = await selectSummaryScreenshots(images, signal(), selector, read);
    expect({ ids: ids(result.images), method: result.method }).toEqual({ ids: ["file-0", "file-19"], method: "model" });
    expect(peak).toBeGreaterThan(1);
    expect(peak).toBeLessThanOrEqual(8);
  });

  it("shows the model exactly 240 candidates spread across a long meeting", async () => {
    const images = Array.from({ length: 241 }, (_, index) => screenshot(index));
    let shown: readonly { capturedAt: Date }[] = [];
    const selector: ScreenshotSelector = { select: async (inputs) => { shown = inputs; return [0]; } };
    await selectSummaryScreenshots(images, signal(), selector, async () => new Uint8Array([1]));
    expect(shown).toHaveLength(240);
    expect([shown[0]!.capturedAt, shown[239]!.capturedAt]).toEqual([images[0]!.capturedAt, images[240]!.capturedAt]);
  });

  it("treats an empty selection as no useful screenshot, even for a lone candidate", async () => {
    const select = vi.fn(async () => []);
    const selector: ScreenshotSelector = { select };
    expect(await selectSummaryScreenshots([screenshot(0), screenshot(1)], signal(), selector, async () => new Uint8Array([1])))
      .toEqual({ images: [], method: "model" });
    expect(await selectSummaryScreenshots([screenshot(0)], signal(), selector, async () => new Uint8Array([1])))
      .toEqual({ images: [], method: "model" });
    expect(select).toHaveBeenCalledTimes(2);
  });

  it("falls back to even sampling with a content-free failure code", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const images = [0, 1, 2].map((index) => screenshot(index));
    const failing: ScreenshotSelector = { select: async () => { throw new Error("upstream"); } };
    expect(await selectSummaryScreenshots(images, signal(), failing, async () => new Uint8Array([1]), 2))
      .toEqual({ images: [images[0], images[2]], method: "even" });
    expect(ids((await selectSummaryScreenshots(images, signal(), failing, async () => { throw new Error("missing"); }, 2)).images)).toEqual(["file-0", "file-2"]);
    const slow: ScreenshotSelector = { select: (_images, _limit, deadline) => new Promise((_, reject) => {
      deadline.addEventListener("abort", () => reject(deadline.reason as Error));
    }) };
    expect(await selectSummaryScreenshots(images, signal(), slow, async () => new Uint8Array([1]), 2, 20))
      .toMatchObject({ method: "even" });
    expect(warn.mock.calls.map(([line]) => JSON.parse(String(line)) as { code: string }).map((line) => line.code))
      .toEqual(["image_unavailable", "image_unavailable", "timeout"]);
    expect(JSON.stringify(warn.mock.calls)).not.toContain("never sent");
    warn.mockRestore();
    expect(await selectSummaryScreenshots(images, signal(), undefined, undefined, 24)).toEqual({ images, method: "even" });
  });

  it("propagates cancellation instead of sampling", async () => {
    const controller = new AbortController();
    const selector: ScreenshotSelector = { select: async () => { controller.abort(); throw new Error("aborted"); } };
    await expect(selectSummaryScreenshots([screenshot(0), screenshot(1)], controller.signal, selector, async () => new Uint8Array([1])))
      .rejects.toBeDefined();
  });

  it("sends only indexed low-detail images to the image analysis model and validates the indices", async () => {
    let answer: unknown = { indices: [2] };
    const transport = vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
      if (String(url).endsWith("/token")) return Response.json({ access_token: "app-token", expires_in: 3600 });
      const body = JSON.parse(String(init?.body)) as { model: string; instructions: string; input: { content: { type: string; text?: string; image_url?: string }[] }[] };
      expect(body.model).toBe("system.ai.gpt-5-6-luna");
      expect(body.instructions).toContain("Select at most 24 images");
      expect(body.input[0]!.content).toEqual([
        { type: "input_text", text: '<image index="1" elapsed_seconds="0"/>' },
        { type: "input_image", detail: "low", image_url: "data:image/webp;base64,AQ==" },
        { type: "input_text", text: '<image index="2" elapsed_seconds="30"/>' },
        { type: "input_image", detail: "low", image_url: "data:image/webp;base64,Ag==" },
      ]);
      return Response.json({ status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify(answer) }] }] });
    });
    const selector = createScreenshotSelector(loadConfig(environment), transport)!;
    const inputs = [{ data: new Uint8Array([1]), capturedAt: new Date(0) }, { data: new Uint8Array([2]), capturedAt: new Date(30_000) }];
    expect(await selector.select(inputs, 24, signal())).toEqual([1]);
    for (answer of [{ indices: [3] }, { indices: "1" }]) {
      await expect(selector.select(inputs, 24, signal())).rejects.toMatchObject({ code: "invalid_response" });
    }
    expect(createScreenshotSelector(loadConfig({ ...environment, DAHLIA_IMAGE_ANALYSIS_MODEL: "" }), transport)).toBeUndefined();
  });
});

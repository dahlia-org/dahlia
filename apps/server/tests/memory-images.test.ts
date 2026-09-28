import { describe, expect, it, vi } from "vitest";
import { imageDocument, imageReferences, validImageLineage, type ImageSettings } from "../src/memory/images";
import { HindsightClient } from "../src/memory/hindsight";
import type { MeetingSyncService } from "../src/sync/service";
import { canonicalJson } from "../src/sync/service";
import type { MeetingSyncStore, SyncScreenshotRecord } from "../src/sync/types";
import type { MemoryDocument } from "../src/memory/model";
import { contentHash } from "../src/memory/sources";
import { ingestionFingerprint } from "../src/memory/ingestion";
import { RequestError } from "../src/storage/upload";
import { uuidV7 } from "../src/id";
import { encodeId } from "../src/typeid";

const settings: ImageSettings = { model: "system.ai.gpt-6-luna", maxCount: 8, maxBytes: 8 * 1024 * 1024, longEdge: 1568 };
const signal = new AbortController().signal;
async function fixture(count = 2) {
  const workspaceId = uuidV7(), meetingId = uuidV7();
  const identity = { userId: uuidV7(), source: "accounts" as const };
  const shots: SyncScreenshotRecord[] = [];
  for (let i = 0; i < count; i++) shots.push({ workspaceId, meetingId, screenshotId: uuidV7(), fileId: uuidV7(), capturedAt: new Date(i * 1000),
    contentHash: await contentHash(`image-${i}`), contentLength: 7, storageKey: "unused", contentType: "image/webp", ocrText: `OCR-${i}`, caption: `CAPTION-${i}` });
  const parts = ["Canonical transcript", ...shots.map((shot) => `[Screenshot ${shot.screenshotId}] ${shot.ocrText} ${shot.caption}`)];
  let offset = 0;
  const blocks = parts.map((text, i) => { const start = offset; offset += text.length + 2;
    return { start, end: start + text.length, ...(i ? { marker: `Screenshot ${shots[i - 1]!.screenshotId}` } : {}) }; });
  const document: MemoryDocument = { id: `meeting-${meetingId}`, source: { id: meetingId, kind: "meeting", projectId: null, revision: "canonical" },
    screenshotPositions: Object.fromEntries(shots.map((shot, i) => [shot.screenshotId, { blockIndex: i + 1, textBlock: true }])),
    content: parts.join("\n\n"), timestamp: new Date(0).toISOString(), blocks, screenshots: shots };
  const files = new Map(shots.map((shot) => [shot.fileId, { fileId: shot.fileId, workspaceId, checksum: `SHA-256:${shot.contentHash}`, metadata: { source: "screenshot" } }]));
  const scoped = { listUninformativeScreenshots: vi.fn().mockResolvedValue([]), getFile: vi.fn(async (id: string) => files.get(id)),
    getScreenshot: vi.fn(async (_workspace: string, _meeting: string, id: string) => shots.find((shot) => shot.screenshotId === id)) };
  const store = { withIdentity: vi.fn(async (_identity: unknown, fn: (value: typeof scoped) => Promise<unknown>) => fn(scoped)) } as unknown as MeetingSyncStore;
  const readFileContent = vi.fn(async (_identity, fileId: string) => ({ upstream: new Response(`image-${shots.findIndex((shot) => shot.fileId === fileId)}`) }));
  const getWorkspace = vi.fn().mockResolvedValue({ workspaceId }), getMeeting = vi.fn().mockResolvedValue({ meetingId });
  const sync = { readFileContent, getWorkspace, getMeeting } as unknown as MeetingSyncService;
  const prepare = (options = settings, previous = undefined as MemoryDocument["source"]["images"], materialize = true, deadline = signal) =>
    imageDocument(document, sync, store, identity, workspaceId, options, deadline, previous, materialize);
  return { document, shots, scoped, files, readFileContent, getWorkspace, getMeeting, prepare };
}

describe("Memory inline screenshots", () => {
  it("keeps one canonical document while omitting selected OCR/caption only from retain", async () => {
    const f = await fixture();
    const sent = await f.prepare({ ...settings, maxCount: 1 });
    expect(sent.id).toBe(f.document.id);
    expect(sent.content).toBe(f.document.content);
    expect(sent.source.revision).toBe("canonical");
    const serialized = JSON.stringify(sent.retainContent);
    expect(serialized).not.toContain("OCR-0"); expect(serialized).not.toContain("CAPTION-0");
    expect(serialized.indexOf("base64")).toBeLessThan(serialized.indexOf("OCR-1"));
    expect(serialized).toContain("OCR-1"); expect(serialized).toContain("CAPTION-1");
    expect(sent.retainContent!.filter((block) => block.type === "image")).toHaveLength(1);
    expect(sent.source.images).toMatchObject({ eligible: 2, omitted: 1 });
    expect(imageReferences(sent)[0]!.href).toBe(`/api/v1/files/${encodeId("file", f.shots[0]!.fileId)}/content`);
    const wire = vi.fn<typeof fetch>().mockResolvedValue(Response.json({ operation_id: "operation" }));
    const client = new HindsightClient({ url: "https://memory.invalid", auth: "none", bankPrefix: "test" }, undefined, wire);
    await client.retain("server-derived-bank", sent, "operation", signal);
    const body = JSON.parse(String(wire.mock.calls[0]![1]!.body)) as { items: Array<{ document_id: string; metadata: { dahlia_image_manifest: string } }> };
    expect(body.items).toHaveLength(1);
    expect(body.items[0]!.document_id).toBe(sent.id);
    expect(body.items[0]!.metadata.dahlia_image_manifest).toBe(canonicalJson(sent.source.images));
  });
  it("reuses current immutable manifests for publication and invalidates changed selection or bytes", async () => {
    const f = await fixture(10), sent = await f.prepare();
    const cached = await f.prepare(settings, sent.source.images, false);
    expect(f.readFileContent).toHaveBeenCalledTimes(5); // existing even-sampling contract
    expect(cached.source).toEqual(sent.source);
    const changed = await f.prepare({ ...settings, maxCount: 3 }, sent.source.images, false);
    expect(changed.source.images!.selectionHash).not.toBe(sent.source.images!.selectionHash);
    expect(await ingestionFingerprint("same-text", changed.source, "policy")).not.toBe(await ingestionFingerprint("same-text", sent.source, "policy"));
    f.files.get(f.shots[0]!.fileId)!.checksum = `SHA-256:${"0".repeat(64)}`;
    await expect(f.prepare(settings, sent.source.images, false)).rejects.toMatchObject({ code: "memory_image_changed" });
  });
  it("reuses usefulness and duplicate filtering", async () => {
    const f = await fixture(3);
    f.shots[1]!.contentHash = f.shots[0]!.contentHash;
    f.scoped.listUninformativeScreenshots.mockResolvedValue([f.shots[2]!.fileId]);
    expect((await f.prepare()).source.images!.entries).toHaveLength(1);
  });
  it("rejects oversized, unavailable and cancelled reads without text-only success", async () => {
    const f = await fixture();
    await expect(f.prepare({ ...settings, maxBytes: 3 })).rejects.toMatchObject({ code: "memory_image_too_large" });
    f.readFileContent.mockResolvedValue({ upstream: new Response(null, { status: 503 }) });
    await expect(f.prepare()).rejects.toMatchObject({ code: "memory_image_unavailable" });
    f.readFileContent.mockResolvedValue({ upstream: new Response(new ReadableStream({
      start(controller) { controller.enqueue(new Uint8Array([1])); },
      pull(controller) { controller.error(new Error("SYNTHETIC_PRIVATE_STREAM_FAILURE")); },
    })) });
    await expect(f.prepare()).rejects.toMatchObject({ code: "memory_image_unavailable", message: "memory_image_unavailable" });
    const controller = new AbortController(); controller.abort();
    await expect(f.prepare(settings, undefined, true, controller.signal)).rejects.toBeDefined();
  });
  it("bounds permanent image errors but preserves revoked access and stalled-read cancellation", async () => {
    const f = await fixture(1);
    f.readFileContent.mockRejectedValue(new RequestError(404, "file_variant_unavailable"));
    await expect(f.prepare()).rejects.toMatchObject({ code: "memory_image_unavailable" });
    f.getWorkspace.mockResolvedValue(null);
    await expect(f.prepare()).rejects.toMatchObject({ code: "workspace_not_found" });
    f.getWorkspace.mockResolvedValue({});
    f.readFileContent.mockRejectedValue(new Error("SYNTHETIC_PRIVATE_TRANSFORM_FAILURE"));
    await expect(f.prepare()).rejects.toMatchObject({ code: "memory_image_unavailable" });
    const cancel = vi.fn(), controller = new AbortController();
    f.readFileContent.mockResolvedValue({ upstream: new Response(new ReadableStream({ cancel })) });
    const result = f.prepare(settings, undefined, true, controller.signal);
    await vi.waitFor(() => expect(f.readFileContent).toHaveBeenCalledTimes(4));
    controller.abort();
    await expect(result).rejects.toMatchObject({ name: "AbortError" });
    expect(cancel).toHaveBeenCalled();
  });
  it("inserts a selected screenshot without OCR at its original assembly position", async () => {
    const f = await fixture(2);
    f.document.blocks!.splice(1, 1);
    f.document.screenshotPositions![f.shots[0]!.screenshotId] = { blockIndex: 1, textBlock: false };
    f.document.screenshotPositions![f.shots[1]!.screenshotId] = { blockIndex: 1, textBlock: true };
    const sent = await f.prepare({ ...settings, maxCount: 1 });
    expect(sent.retainContent?.map((block) => block.type)).toEqual(["text", "text", "image", "text"]);
    expect(JSON.stringify(sent.retainContent)).toContain("OCR-1");
    f.shots[0]!.capturedAt = new Date(500);
    const updated = await f.prepare({ ...settings, maxCount: 1 }, sent.source.images);
    expect(updated.content).toBe(sent.content);
    expect(updated.source.revision).toBe(sent.source.revision);
    expect(updated.retainedText).not.toBe(sent.retainedText);
    expect(await ingestionFingerprint("same-text", updated.source, "policy")).not.toBe(await ingestionFingerprint("same-text", sent.source, "policy"));
  });
  it("rechecks file and screenshot authorization after storage reads", async () => {
    const f = await fixture(1);
    f.readFileContent.mockImplementation(async () => { f.files.clear(); return { upstream: new Response("image-0") }; });
    await expect(f.prepare()).rejects.toMatchObject({ code: "memory_image_changed" });
  });
  it("requires structured image edges from the same document and rejects OCR-only provenance", async () => {
    const f = await fixture(1), sent = await f.prepare(), entry = sent.source.images!.entries[0]!;
    const attachment = { id: entry.attachmentId, hash: entry.hash, byte_size: entry.bytes, kind: "image" as const, media_type: "image/webp" as const };
    const metadata = { dahlia_image_manifest: canonicalJson(sent.source.images), dahlia_image_context: [entry.attachmentId] };
    expect(validImageLineage(sent, [attachment], metadata)).toBe(true);
    expect(validImageLineage(sent, [], metadata)).toBe(false);
    expect(validImageLineage(sent, [attachment], {})).toBe(false);
    expect(validImageLineage(sent, [{ ...attachment, hash: "0".repeat(64) }], metadata)).toBe(false);
    expect(validImageLineage(sent, [], { ...metadata, dahlia_image_context: [] })).toBe(true);
  });
});

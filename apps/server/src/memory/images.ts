import { z } from "zod";
import type { Identity } from "../auth/identity";
import { canonicalJson, type MeetingSyncService } from "../sync/service";
import type { MeetingSyncStore } from "../sync/types";
import { sampleEvenly, summaryScreenshotCandidates } from "../sync/screenshot-selection";
import { RequestError } from "../storage/upload";
import { encodeId } from "../typeid";
import { HindsightError } from "./errors";
import type { MemoryDocument } from "./model";
import { contentHash } from "./sources";

export interface ImageSettings { model: string; maxCount: number; maxBytes: number; longEdge: 480 | 1280 | 1568 | 1920 }
export interface ImageEntry {
  documentId: string; screenshotId: string; fileId: string; checksum: string;
  hash: string; attachmentId: string; bytes: number; variant: string;
}
export interface ImageManifest { version: 1; selectionHash: string; eligible: number; omitted: number; entries: ImageEntry[] }
export type ImageContentBlock = { type: "text"; text: string } | { type: "image"; source: { type: "base64"; media_type: "image/webp"; data: string } };
export const attachmentSchema = z.object({ id: z.string().regex(/^[0-9a-f]{12}$/), hash: z.string().regex(/^[0-9a-f]{64}$/),
  kind: z.literal("image"), media_type: z.literal("image/webp"), byte_size: z.number().int().positive() });
export const imageCoverageSchema = z.object({ selected: z.number().int().nonnegative(), eligible: z.number().int().nonnegative(), omitted: z.number().int().nonnegative() });
export function imageCoverage(document: MemoryDocument) { const manifest = document.source.images; return manifest ? { selected: manifest.entries.length, eligible: manifest.eligible, omitted: manifest.omitted } : undefined; }
export const imageReferenceSchema = z.object({ screenshotId: z.string(), fileId: z.string(), checksum: z.string(), href: z.string() });

export function imageReferences(document: MemoryDocument) {
  return (document.source.images?.entries ?? []).map((entry) => ({ screenshotId: encodeId("attachment", entry.screenshotId),
    fileId: encodeId("file", entry.fileId), checksum: entry.checksum,
    href: `/api/v1/files/${encodeId("file", entry.fileId)}/content` }));
}

export function validImageLineage(document: MemoryDocument, attachments: z.infer<typeof attachmentSchema>[] | null | undefined,
  metadata?: Record<string, unknown> | null) {
  const images = document.source.images;
  if (images && metadata?.dahlia_image_manifest !== canonicalJson(images)) return false;
  const context = metadata?.dahlia_image_context;
  // A multimodal extraction without an explicit fact edge cannot establish image provenance.
  if (Array.isArray(context) && context.length && !attachments?.length) return false;
  if (images?.entries.length && !Array.isArray(context)) return false;
  if (Array.isArray(context) && context.some((id) => !images?.entries.some((entry) => entry.attachmentId === id))) return false;
  return (attachments ?? []).every((attachment) => images?.entries.some((entry) => entry.documentId === document.id
    && entry.attachmentId === attachment.id && entry.hash === attachment.hash && entry.bytes === attachment.byte_size)
    && Array.isArray(context) && context.includes(attachment.id));
}

async function hashBytes(bytes: Uint8Array<ArrayBuffer>) {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
async function boundedImage(response: Response, limit: number, signal: AbortSignal) {
  if (!response.ok || !response.body) { await response.body?.cancel(); throw new HindsightError("memory_image_unavailable"); }
  const reader = response.body.getReader(), parts: Uint8Array[] = [];
  const cancel = () => { void reader.cancel().catch(() => undefined); };
  signal.addEventListener("abort", cancel, { once: true });
  let size = 0;
  try {
    for (;;) {
      signal.throwIfAborted();
      const { value, done } = await reader.read();
      signal.throwIfAborted();
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw new HindsightError("memory_image_too_large");
      parts.push(value);
    }
  } catch (error) {
    signal.throwIfAborted();
    if (error instanceof HindsightError) throw error;
    throw new HindsightError("memory_image_unavailable");
  } finally { signal.removeEventListener("abort", cancel); await reader.cancel().catch(() => undefined); }
  if (!size) throw new HindsightError("memory_image_unavailable");
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.length; }
  return bytes;
}

// No image bytes are persisted in the job or application database. Publication checks can reuse
// the sent digest only while the immutable canonical file checksum and selection are unchanged.
export async function imageDocument(document: MemoryDocument, sync: MeetingSyncService, store: MeetingSyncStore,
  identity: Identity, workspaceId: string, settings: ImageSettings, signal: AbortSignal,
  saved?: ImageManifest, materialize = false): Promise<MemoryDocument> {
  const excluded = await store.withIdentity(identity, (scoped) => scoped.listUninformativeScreenshots(workspaceId, document.source.id));
  const shots = document.screenshots ?? [];
  const candidates = summaryScreenshotCandidates(shots, excluded);
  const selected = sampleEvenly(candidates, settings.maxCount);
  const selectionHash = await contentHash(canonicalJson({ settings, shots: shots.map((shot) => [shot.screenshotId, shot.fileId, shot.contentHash, shot.capturedAt.toISOString()]), excluded }));
  const entries: ImageEntry[] = [], blocks: ImageContentBlock[] = [];
  let used = 0;
  const images = new Map<string, ImageContentBlock>();
  for (const shot of selected) {
    signal.throwIfAborted();
    const file = await store.withIdentity(identity, (scoped) => scoped.getFile(shot.fileId, true));
    if (!file || file.workspaceId !== workspaceId || file.metadata.source !== "screenshot"
      || file.checksum !== `SHA-256:${shot.contentHash}`) throw new HindsightError("memory_image_changed");
    const variant = `thumb_${settings.longEdge}` as const;
    const prior = saved?.selectionHash === selectionHash ? saved.entries.find((entry) => entry.screenshotId === shot.screenshotId
      && entry.fileId === shot.fileId && entry.checksum === file.checksum && entry.variant === variant) : undefined;
    let entry = prior;
    if (!entry || materialize) {
      const { upstream } = await sync.readFileContent(identity, shot.fileId, variant, "GET", new Request("https://dahlia.invalid/", { signal })).catch(async (error: unknown) => {
        signal.throwIfAborted();
        if (error instanceof RequestError && error.status < 500) {
          // A missing/unsupported file is different from revoked canonical access.
          // Recheck that boundary before classifying this as a bounded image failure.
          if (!await sync.getWorkspace(identity, workspaceId)) throw new RequestError(404, "workspace_not_found");
          if (!await sync.getMeeting(identity, workspaceId, document.source.id)) throw new HindsightError("memory_image_changed");
        }
        throw new HindsightError("memory_image_unavailable");
      });
      const bytes = await boundedImage(upstream, Math.min(4 * 1024 * 1024, settings.maxBytes - used), signal);
      const hash = await hashBytes(bytes);
      entry = { documentId: document.id, screenshotId: shot.screenshotId, fileId: shot.fileId, checksum: file.checksum,
        hash, attachmentId: hash.slice(0, 12), bytes: bytes.byteLength, variant };
      if (materialize) {
        let binary = "";
        for (let offset = 0; offset < bytes.length; offset += 8192) binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
        images.set(shot.screenshotId, { type: "image", source: { type: "base64", media_type: "image/webp", data: btoa(binary) } });
      }
    }
    used += entry.bytes;
    if (used > settings.maxBytes) throw new HindsightError("memory_image_too_large");
    const current = await store.withIdentity(identity, async (scoped) => ({
      file: await scoped.getFile(shot.fileId, true), shot: await scoped.getScreenshot(workspaceId, document.source.id, shot.screenshotId, true),
    }));
    if (!current.file || current.file.checksum !== entry.checksum || current.shot?.fileId !== entry.fileId) throw new HindsightError("memory_image_changed");
    entries.push(entry);
  }
  const manifest: ImageManifest = { version: 1, selectionHash, eligible: candidates.length, omitted: candidates.length - selected.length, entries };
  const sourceBlocks = document.blocks ?? [];
  for (let index = 0; index <= sourceBlocks.length; index++) {
    const atPosition = selected.filter((shot) => document.screenshotPositions?.[shot.screenshotId]?.blockIndex === index);
    for (const shot of atPosition) {
      blocks.push({ type: "text", text: `Screenshot captured at ${shot.capturedAt.toISOString()}\n\n` }, images.get(shot.screenshotId) ?? { type: "image", source: { type: "base64", media_type: "image/webp", data: "" } });
    }
    const block = sourceBlocks[index];
    if (block && !atPosition.some((shot) => document.screenshotPositions![shot.screenshotId]!.textBlock)) {
      blocks.push({ type: "text", text: `${document.content.slice(block.start, block.end)}\n\n` });
    }
  }
  if (blocks.filter((block) => block.type === "image").length !== selected.length) throw new HindsightError("memory_image_changed");
  let retainedText = "", afterImage = false, imageIndex = 0;
  for (const block of blocks) {
    if (block.type === "text") {
      // Never re-reference an old image using text supplied by a source.
      block.text = block.text.replace(/⟦hs-att:[^⟧]*⟧/gu, "");
      if (afterImage && retainedText) retainedText = `${retainedText.replace(/\n+$/u, "")}\n\n`;
      retainedText += block.text; afterImage = false;
    } else {
      if (retainedText) retainedText = `${retainedText.replace(/\n+$/u, "")}\n\n`;
      retainedText += `⟦hs-att:${entries[imageIndex++]!.attachmentId}⟧`; afterImage = true;
    }
  }
  return { ...document, retainedText, source: { ...document.source, images: manifest }, ...(materialize ? { retainContent: blocks } : {}) };
}

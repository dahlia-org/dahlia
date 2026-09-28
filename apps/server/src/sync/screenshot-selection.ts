import type { SyncScreenshotRecord } from "./types";

/** Drops screenshots image analysis found to have no shared material, and identical images. */
export function summaryScreenshotCandidates(images: readonly SyncScreenshotRecord[], uninformative: readonly string[]) {
  const excluded = new Set(uninformative);
  const hashes = new Set<string>();
  return images.filter((image) => {
    if (excluded.has(image.fileId) || hashes.has(image.contentHash)) return false;
    hashes.add(image.contentHash);
    return true;
  });
}

export function sampleEvenly<T>(items: readonly T[], limit: number): T[] {
  const interval = Math.max(1, Math.ceil(items.length / limit));
  return items.filter((_, index) => index % interval === 0).slice(0, limit);
}

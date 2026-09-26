import type { ScreenshotAssessment } from "../image-analysis/model";
import type { SyncScreenshotRecord } from "../sync/types";

export const SUMMARY_IMAGE_LIMIT = 24;

/**
 * Drops screenshots image analysis marked as uninformative or unchanged from their predecessor, and exact
 * duplicates, then samples the rest evenly in capture order. Unassessed screenshots stay eligible.
 */
export function selectSummaryScreenshots(images: readonly SyncScreenshotRecord[],
  assessments: readonly ScreenshotAssessment[], limit = SUMMARY_IMAGE_LIMIT): SyncScreenshotRecord[] {
  const byFile = new Map(assessments.map((assessment) => [assessment.fileId, assessment]));
  const present = new Set(images.map((image) => image.fileId));
  const hashes = new Set<string>();
  const candidates = images.filter((image) => {
    const assessment = byFile.get(image.fileId);
    if (assessment?.informative === false) return false;
    // A duplicate stays when the screenshot it repeats is no longer attached to the meeting.
    if (assessment?.duplicateOfFileId && present.has(assessment.duplicateOfFileId)) return false;
    if (hashes.has(image.contentHash)) return false;
    hashes.add(image.contentHash);
    return true;
  });
  const interval = Math.max(1, Math.ceil(candidates.length / limit));
  return candidates.filter((_, index) => index % interval === 0).slice(0, limit);
}

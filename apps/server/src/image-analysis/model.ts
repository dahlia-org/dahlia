import { z } from "zod";
import { codePointLimitedString, fileMetadataLimits, type FileRecord } from "../files/model";

export interface ImageAnalysisClaim {
  fileId: string;
  workspaceId: string;
  ownerUserId: string;
  model: string;
  mode: "fill_missing" | "replace";
  outputLanguage: string;
  attempts: number;
  claimedAt: Date;
}

export interface ImageAnalysisInput extends ImageAnalysisClaim {
  file: FileRecord;
}

export const IMAGE_ANALYSIS_REASON_LIMIT = 200;
export const imageAnalysisSchema = z.object({
  ocr_text: codePointLimitedString(z.string(), fileMetadataLimits.api.ocrText),
  caption: codePointLimitedString(z.string().trim().min(1), fileMetadataLimits.api.caption),
  // Selection hints for summaries; stored outside synced file metadata.
  informative: z.boolean(),
  reason: codePointLimitedString(z.string().trim().min(1), IMAGE_ANALYSIS_REASON_LIMIT),
  same_as_previous: z.boolean(),
}).strict();
export type ImageAnalysis = z.infer<typeof imageAnalysisSchema>;

export interface ScreenshotAssessment {
  fileId: string;
  informative: boolean;
  reason: string | null;
  duplicateOfFileId: string | null;
}

export function needsImageAnalysis(metadata: FileRecord["metadata"], mode: ImageAnalysisClaim["mode"] = "fill_missing", assessed = true): boolean {
  return mode === "replace" || metadata.ocr_text == null || !metadata.caption?.trim()
    || (metadata.source === "screenshot" && !assessed);
}

export class ImageAnalysisError extends Error {
  constructor(readonly code: string, readonly retryable: boolean) {
    super(code);
  }
}

import { z } from "zod";
import { codePointLimitedString, fileMetadataLimits, type FileRecord } from "../files/model";

export interface ImageAnalysisClaim {
  fileId: string;
  vaultId: string;
  ownerUserId: string;
  model: string;
  attempts: number;
  claimedAt: Date;
}

export interface ImageAnalysisInput extends ImageAnalysisClaim {
  file: FileRecord;
}

export const imageAnalysisSchema = z.object({
  ocr_text: codePointLimitedString(z.string(), fileMetadataLimits.api.ocrText),
  caption: codePointLimitedString(z.string().trim().min(1), fileMetadataLimits.api.caption),
}).strict();
export type ImageAnalysis = z.infer<typeof imageAnalysisSchema>;

export function needsImageAnalysis(metadata: FileRecord["metadata"]): boolean {
  return metadata.ocr_text == null || !metadata.caption?.trim();
}

export class ImageAnalysisError extends Error {
  constructor(readonly code: string, readonly retryable: boolean) {
    super(code);
  }
}

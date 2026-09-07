import { z } from "zod";
import type { FileRecord } from "../files/model";

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
  ocr_text: z.string().max(20_000),
  caption: z.string().trim().min(1).max(500),
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

import { z } from "zod";
import { screenshotVariantKey, type ScreenshotVariant } from "../sync/screenshot-variants";

const fileDimensionSchema = z.number().int().positive().max(33_554_432);

export const fileMetadataSchema = z.object({
  source: z.enum(["upload", "screenshot"]),
  width: fileDimensionSchema.optional(),
  height: fileDimensionSchema.optional(),
  ocr_text: z.string().max(20_000).nullable().optional(),
  caption: z.string().max(500).nullable().optional(),
}).strict();
export type FileMetadata = z.infer<typeof fileMetadataSchema>;

// The database metadata stays unchanged; the HTTP contract uses camelCase.
export const fileWireMetadataSchema = fileMetadataSchema.omit({ ocr_text: true }).extend({
  ocrText: fileMetadataSchema.shape.ocr_text,
}).strict();
export function fileMetadataFromWire(value: Partial<z.infer<typeof fileWireMetadataSchema>>): Partial<FileMetadata> {
  const { ocrText, ...metadata } = value;
  return { ...metadata, ...(ocrText !== undefined ? { ocr_text: ocrText } : {}) };
}
export const fileUploadSchema = z.object({
  id: z.uuidv7().transform((id) => id.toLowerCase()), vaultId: z.uuid().transform((id) => id.toLowerCase()), name: z.string().min(1).max(255),
  contentType: z.string().max(255).regex(/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/),
  metadata: fileWireMetadataSchema.pick({ source: true, width: true, height: true }),
}).strict();

export const filePatchSchema = z.object({
  baseRevision: z.number().int().positive(),
  metadata: fileWireMetadataSchema.omit({ source: true }).partial(),
}).strict();

export interface FileRecord {
  fileId: string;
  vaultId: string;
  uri: string;
  offset: number;
  size: number;
  contentType: string;
  checksum: string;
  name: string;
  metadata: FileMetadata;
  active: boolean;
  uploadedAt: Date | null;
  revision: number;
  createdAt: Date;
  updatedAt: Date;
}

export interface MeetingFileRecord {
  id: string;
  vaultId: string;
  meetingId: string;
  fileId: string;
  capturedAt: Date | null;
  sessionId: string | null;
  createdAt: Date;
  revision: number;
}

export const fileStorageKey = (id: string) => `files/${id}/original`;
export const fileVariantKey = (id: string, variant: ScreenshotVariant) => screenshotVariantKey(fileStorageKey(id), variant);
export const imageContentTypes = new Set(["image/png", "image/jpeg", "image/webp", "image/gif", "image/tiff"]);

export function fileResponse(file: FileRecord) {
  const { ocr_text, ...metadata } = file.metadata;
  return {
    id: file.fileId, vaultId: file.vaultId, size: file.size,
    contentType: file.contentType, checksum: file.checksum, name: file.name,
    metadata: { ...metadata, ...(ocr_text !== undefined ? { ocrText: ocr_text } : {}) },
    revision: file.revision, createdAt: file.createdAt, updatedAt: file.updatedAt,
  };
}

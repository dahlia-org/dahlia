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

const dimensionQuerySchema = z.string().regex(/^[1-9][0-9]*$/)
  .transform(Number).pipe(fileDimensionSchema);

export const fileUploadQuerySchema = z.object({
  id: z.uuidv7().transform((id) => id.toLowerCase()),
  vaultId: z.uuid().transform((id) => id.toLowerCase()),
  name: z.string().min(1).max(255),
  source: fileMetadataSchema.shape.source,
  width: dimensionQuerySchema.optional(),
  height: dimensionQuerySchema.optional(),
}).strict();

export const filePatchSchema = z.object({
  baseRevision: z.number().int().positive(),
  metadata: fileMetadataSchema.omit({ source: true }).partial(),
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
  return {
    id: file.fileId, vaultId: file.vaultId, uri: file.uri, offset: file.offset, size: file.size,
    content_type: file.contentType, checksum: file.checksum, name: file.name, metadata: file.metadata,
    revision: file.revision, createdAt: file.createdAt, updatedAt: file.updatedAt,
  };
}

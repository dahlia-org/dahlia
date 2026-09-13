import { z } from "@hono/zod-openapi";
import { screenshotVariantKey, type ScreenshotVariant } from "../sync/screenshot-variants";

const fileDimensionSchema = z.number().int().positive().max(33_554_432);
export const fileMetadataLimits = {
  api: { ocrText: 32_768, caption: 1_024 },
  postgres: { ocrText: 65_536, caption: 2_048 },
} as const;

export function codePointLimitedString(schema: z.ZodString, maxLength: number) {
  return schema.refine((value) => {
    const iterator = value[Symbol.iterator]();
    for (let count = 0; count <= maxLength; count += 1) {
      if (iterator.next().done) return true;
    }
    return false;
  }).meta({ maxLength });
}

function metadataSchema(ocrTextLimit: number, captionLimit: number) {
  return z.object({
    source: z.enum(["upload", "screenshot"]),
    width: fileDimensionSchema.optional(),
    height: fileDimensionSchema.optional(),
    ocr_text: codePointLimitedString(z.string(), ocrTextLimit).nullable().optional(),
    caption: codePointLimitedString(z.string(), captionLimit).nullable().optional(),
  }).strict();
}

export const fileMetadataSchema = metadataSchema(fileMetadataLimits.api.ocrText, fileMetadataLimits.api.caption);
const persistedFileMetadataSchema = metadataSchema(fileMetadataLimits.postgres.ocrText, fileMetadataLimits.postgres.caption);
export type FileMetadata = z.infer<typeof persistedFileMetadataSchema>;

// The database metadata stays unchanged; the HTTP contract uses camelCase.
export const fileWireMetadataSchema = fileMetadataSchema.omit({ ocr_text: true }).extend({
  ocrText: fileMetadataSchema.shape.ocr_text,
}).strict().openapi("FileWriteMetadata");
export const fileWireResponseMetadataSchema = persistedFileMetadataSchema.omit({ ocr_text: true }).extend({
  ocrText: persistedFileMetadataSchema.shape.ocr_text,
}).strict().openapi("FileMetadata");
export function fileMetadataFromWire(value: Partial<z.infer<typeof fileWireMetadataSchema>>): Partial<FileMetadata> {
  const { ocrText, ...metadata } = value;
  return { ...metadata, ...(ocrText !== undefined ? { ocr_text: ocrText } : {}) };
}
export const fileUploadSchema = z.object({
  id: z.uuidv7().meta({ format: "uuidv7" }).transform((id) => id.toLowerCase()), workspaceId: z.uuid().transform((id) => id.toLowerCase()), name: z.string().min(1).max(255),
  contentType: z.string().max(255).regex(/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/),
  metadata: fileWireMetadataSchema.pick({ source: true, width: true, height: true }),
}).strict();

export const filePatchSchema = z.object({
  baseRevision: z.number().int().positive(),
  metadata: fileWireMetadataSchema.omit({ source: true }).partial(),
}).strict();

export interface FileRecord {
  fileId: string;
  workspaceId: string;
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

export interface MeetingAttachmentRecord {
  id: string;
  workspaceId: string;
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
    id: file.fileId, workspaceId: file.workspaceId, size: file.size,
    contentType: file.contentType, checksum: file.checksum, name: file.name,
    metadata: { ...metadata, ...(ocr_text !== undefined ? { ocrText: ocr_text } : {}) },
    revision: file.revision, createdAt: file.createdAt, updatedAt: file.updatedAt,
  };
}

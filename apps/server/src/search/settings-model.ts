import { z } from "zod";

export const SEARCH_FIELDS = ["title", "tags", "description", "summary", "ocr", "caption"] as const;
export type SearchField = typeof SEARCH_FIELDS[number];
const weight = z.number().int().min(1).max(10);
export const searchSettingsSchema = z.object({
  title: weight, tags: weight, description: weight, summary: weight, ocr: weight, caption: weight,
}).strict();
export type SearchSettings = z.infer<typeof searchSettingsSchema>;
export const DEFAULT_SEARCH_SETTINGS: SearchSettings = {
  title: 5, tags: 3, description: 2, summary: 1, ocr: 1, caption: 2,
};

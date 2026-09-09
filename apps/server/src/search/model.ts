import { z } from "zod";

const id = z.uuid().transform((value) => value.toLowerCase());
const date = z.iso.datetime({ offset: true }).transform((value) => new Date(value));
const searchFields = z.object({
  vaultId: id,
  query: z.string().trim().max(500).default(""),
  kind: z.enum(["meeting", "screenshot", "project"]).optional(),
  projectId: id.optional(),
  from: date.optional(),
  to: date.optional(),
  limit: z.number().int().min(1).max(100).default(50),
}).strict();
const validDateRange = ({ from, to }: { from?: Date; to?: Date }) => !from || !to || from < to;
export const searchRequestSchema = searchFields.refine(validDateRange);
export const vaultSearchRequestSchema = searchFields.omit({ vaultId: true }).refine(validDateRange);

export interface SearchHit {
  id: string;
  kind: "meeting" | "screenshot" | "project";
  title: string;
  date: string;
  snippet: string;
  meetingId?: string;
  projectId?: string;
  projectPath?: string;
  fileId?: string;
  meetingCount?: number;
}

export interface SearchResults {
  vaultId: string;
  meetings: SearchHit[];
  screenshots: SearchHit[];
  projects: SearchHit[];
  limited: { meeting: boolean; screenshot: boolean; project: boolean };
}

export function searchSnippet(text: string, query: string): string {
  const position = text.toLocaleLowerCase().indexOf(query.toLocaleLowerCase());
  const start = Math.max(0, position - 50);
  return `${start ? "…" : ""}${text.slice(start, start + 180 - (start ? 1 : 0))}`;
}

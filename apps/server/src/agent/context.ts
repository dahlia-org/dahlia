import { z } from "zod";

import { encodeId } from "@dahlia-ai/ui/model/typeid";

export const aiTimeZoneSchema = z.string().min(1).max(100).refine((timeZone) => {
  try { new Intl.DateTimeFormat("en", { timeZone }); return true; }
  catch { return false; }
}, "Invalid time zone").optional();

function xml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;").replaceAll("'", "&apos;");
}

export function aiContext(workspaceId: string, timeZone = "UTC", now = new Date(), liveContext?: string): string {
  const parts = new Intl.DateTimeFormat("en", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(now);
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find((part) => part.type === type)!.value;
  return [
    "<context>",
    `  <current_datetime>${now.toISOString()}</current_datetime>`,
    `  <current_date>${part("year")}-${part("month")}-${part("day")}</current_date>`,
    `  <timezone>${xml(timeZone)}</timezone>`,
    `  <workspace_id>${encodeId("workspace", workspaceId)}</workspace_id>`,
    ...(liveContext ? [`  <selected_meeting_context>${xml(liveContext)}</selected_meeting_context>`] : []),
    "</context>",
  ].join("\n");
}

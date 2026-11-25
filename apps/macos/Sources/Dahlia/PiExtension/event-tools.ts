// The always-on agent's intake tool. Dahlia validates and stores every field; the model only fills them in.
const item = {
  type: "object",
  properties: {
    external_id: { type: "string", description: "The source's stable ID of the item." },
    topic_key: { type: "string", description: "The ID of the item's conversation, such as a mail thread or a Slack thread." },
    sender: { type: "string" },
    subject: { type: "string" },
    excerpt: { type: "string", description: "A short excerpt, at most a few sentences." },
    url: { type: "string", description: "The item's permalink." },
    ref: { type: "object", description: "The IDs you would pass to the source's tools to read the item again." },
    occurred_at: { type: "string", description: "When the item arrived, in ISO 8601." },
    direct: { type: "boolean", description: "True when the item is addressed to the user or mentions them." },
  },
  required: ["external_id"],
  additionalProperties: false,
};

// shortcut: a result lists items when its JSON text has `items[]` with `id` and `threadId` (Gmail's messages; thread
// listings carry no `threadId` and are skipped). Declare the shape per Source once another service returns one.
export function listedItemIDs(content: any[]): string[] {
  return content.flatMap((part: any) => {
    try {
      const items = JSON.parse(part?.text ?? "")?.items;
      return Array.isArray(items) ? items.filter((item: any) => typeof item?.id === "string" && typeof item?.threadId === "string").map((item: any) => item.id) : [];
    } catch {
      return [];
    }
  });
}

// Preserve the complete request; only JSON object key order and an empty root cursor are irrelevant.
function requestKey(tool: string, input: Record<string, unknown>): string {
  function canonical(value: any): any {
    if (Array.isArray(value)) return value.map(canonical);
    if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
    return value;
  }
  const request = { ...input };
  if (request.cursor === "") delete request.cursor;
  return JSON.stringify([tool, canonical(request)]);
}

// A continuation obligates intake to observe that exact next request, not an inferred search family.
function listedPages(event: any): any[] {
  return (event.content ?? []).flatMap((part: any) => {
    try {
      const result = JSON.parse(part?.text ?? "");
      if (!Array.isArray(result?.items) && result?.has_more === undefined && result?.nextCursor === undefined) return [];
      const input = event.input ?? {};
      const next = typeof result.nextCursor === "string" ? result.nextCursor : "";
      return [{
        requestKey: requestKey(event.toolName, input),
        nextRequestKey: next ? requestKey(event.toolName, { ...input, cursor: next }) : "",
        root: input.cursor === undefined || input.cursor === "",
        hasMore: result.has_more === true,
      }];
    } catch {
      return [];
    }
  });
}

export function registerEventTools(pi: any, bridge: any) {
  // Dahlia moves the read position only once every listed item was recorded or ignored.
  pi.on("tool_result", async (event: any, ctx: any) => {
    if (!event.toolName?.startsWith("mcp__")) return;
    if (event.isError) {
      await bridge(ctx, "intakeReadFailed", {});
      return;
    }
    const ids = listedItemIDs(event.content ?? []);
    // An empty successful result still proves a read occurred; a model-only answer does not.
    const pages = listedPages(event);
    await bridge(ctx, "intakeSeen", { ids, ...(pages.length ? { pages } : {}) });
  });
  pi.registerTool({
    name: "event_record",
    label: "Record events",
    description: "Record items you read from the source in Dahlia's event inbox. Record every item you read; Dahlia removes duplicates and decides what to keep.",
    parameters: { type: "object", properties: { items: { type: "array", items: item } }, required: ["items"], additionalProperties: false },
    execute: async (_id: string, params: unknown, _signal: AbortSignal, _update: unknown, ctx: any) => ({
      content: [{ type: "text", text: JSON.stringify(await bridge(ctx, "eventRecord", params)) }],
    }),
  });
}

const ids = (description: string) => ({ type: "array", items: { type: "string" }, description });
const string = (description: string) => ({ type: "string", description });
const object = (properties: Record<string, unknown>, required: string[]) => ({ type: "object", properties, required, additionalProperties: false });

// Super Agent's own tools. It hands work to threads with the thread tools every chat has; these keep its inbox and Tasks.
export const botTools: Record<string, { name: string; description: string; parameters: unknown }[]> = {
  bot: [
    { name: "inbox_read", description: "Read the events waiting for your decision, your open tasks (threads you launched), and the user's open Items.", parameters: object({}, []) },
    { name: "event_close", description: "Close events that need nothing: noise, or ones already handled. Events you hand to a thread with event_ids close by themselves.", parameters: object({
      event_ids: ids("The events to close."),
    }, ["event_ids"]) },
    { name: "item_create", description: "Show the user a question, a report, or a suggestion in their inbox. Ask one decision per question; the answer comes back to you as an event.", parameters: object({
      kind: { type: "string", enum: ["question", "report", "suggestion"] },
      title: string("One line, under 140 characters. A question ends with ?"),
      body: string("Short context the user needs to decide."),
      options: ids("Up to five answers the user can pick."),
      recommended: { type: "integer", description: "The index of the option you recommend." },
      thread_id: string("The task's thread this Item is about."),
    }, ["kind", "title"]) },
    { name: "task_finish", description: "End a task when nothing more is needed: done, or dismissed when it was not worth doing. A thread that stopped is not a finished task. Sending to its thread again opens it again.", parameters: object({
      thread_id: string("The task's thread."), status: { type: "string", enum: ["done", "dismissed"] },
    }, ["thread_id", "status"]) },
    { name: "soul_write", description: "Replace SOUL.md, the user's standing guidance, when the user asks you to change it. Dahlia shows them the new text to approve.", parameters: object({
      text: string("The whole new SOUL.md."),
    }, ["text"]) },
  ],
};

export function registerBotTools(pi: any, bridge: any, profile: string) {
  for (const tool of botTools[profile] ?? []) {
    pi.registerTool({
      ...tool,
      label: tool.name,
      execute: async (_id: string, args: unknown, _signal: AbortSignal, _update: unknown, ctx: any) => ({
        content: [{ type: "text", text: JSON.stringify(await bridge(ctx, "botTool", { name: tool.name, args })) }],
      }),
    });
  }
}

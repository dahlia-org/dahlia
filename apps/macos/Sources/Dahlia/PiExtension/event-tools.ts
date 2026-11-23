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

// Page evidence comes from the tool result and its actual request, never from the model's completion text.
function listedPages(event: any): any[] {
  return (event.content ?? []).flatMap((part: any) => {
    try {
      const result = JSON.parse(part?.text ?? "");
      if (!Array.isArray(result?.items) && result?.has_more === undefined && result?.nextCursor === undefined) return [];
      return [{
        key: JSON.stringify([event.toolName, event.input?.query ?? ""]),
        cursor: typeof event.input?.cursor === "string" ? event.input.cursor : "",
        nextCursor: typeof result.nextCursor === "string" ? result.nextCursor : "",
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

// Dahlia Bot's Router and Worker tools. Dahlia checks every call against the run's own Task and the user's settings.
export const botTools: Record<string, { name: string; description: string; parameters: unknown }[]> = {
  router: [
    { name: "task_create", description: "Open a task for events that need work, and assign the events to it.", parameters: object({
      title: string("A short title the user will recognize."),
      instructions: string("What the Worker should do and what done means."),
      event_ids: ids("The events this task handles."),
      servers: ids("MCP servers, from the allowed list, the Worker may read for this task."),
    }, ["title", "instructions", "event_ids"]) },
    { name: "task_suggest", description: "Suggest a task for events nobody asked about. The user decides; the events wait until then.", parameters: object({
      title: string("A short title the user will recognize."),
      instructions: string("What the Worker should do if the user agrees, and what done means."),
      body: string("Why you suggest it, in a sentence or two."),
      event_ids: ids("The events this task would handle."),
      servers: ids("MCP servers, from the allowed list, the Worker may read for this task."),
    }, ["title", "instructions", "event_ids"]) },
    { name: "task_assign", description: "Assign events to an open task that already handles their matter.", parameters: object({
      task_id: string("The open task."), event_ids: ids("The events to assign."),
    }, ["task_id", "event_ids"]) },
    { name: "event_close", description: "Close events that need nothing more: noise, or results already reported.", parameters: object({
      event_ids: ids("The events to close."),
    }, ["event_ids"]) },
    { name: "task_finish", description: "End a task that is done or no longer needed.", parameters: object({
      task_id: string("The task."), status: { type: "string", enum: ["done", "dismissed"] },
    }, ["task_id", "status"]) },
    { name: "item_create", description: "Show the user a question, a report, or a suggestion in their inbox. Ask one decision per question.", parameters: object({
      kind: { type: "string", enum: ["question", "report", "suggestion"] },
      title: string("One line, under 140 characters. A question ends with ?"),
      body: string("Short context the user needs to decide."),
      options: ids("Up to five answers the user can pick."),
      recommended: { type: "integer", description: "The index of the option you recommend." },
      task_id: string("The task the answer goes to."),
    }, ["kind", "title"]) },
  ],
  home: [
    { name: "secretary_request", description: "Hand the user's request to their secretary, who opens or continues a task and reports in the inbox.", parameters: object({
      request: string("The request, in the user's words."),
      task_id: string("The open task it continues, if any."),
    }, ["request"]) },
  ],
  worker: [
    { name: "task_report", description: "Report what you found or did. Call it once when you stop; put a question for the user in it when you need their decision.", parameters: object({
      summary: string("The result, with the sources you used."),
      question: string("A question for the user, if you need their decision to continue."),
      options: ids("Up to five answers the user can pick."),
    }, ["summary"]) },
    { name: "task_return", description: "Hand back events that do not belong to this task.", parameters: object({
      event_ids: ids("The events to hand back."),
    }, ["event_ids"]) },
    { name: "task_wait", description: "Come back to this task at a time, for example to check whether a reply arrived.", parameters: object({
      note: string("What to check then."), due_at: string("When, in ISO 8601, within 30 days."),
    }, ["note", "due_at"]) },
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

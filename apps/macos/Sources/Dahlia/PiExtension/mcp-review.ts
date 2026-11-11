import { review } from "./pi-auto-review/index.ts";

// Dahlia adds meeting metadata and live transcripts to user messages; they cannot authorize MCP mutations.
export function reviewBranch(branch: any[]): any[] {
  return branch.flatMap((entry) => {
    if (entry.type !== "message" || entry.message.role !== "user") return [entry];
    const content = entry.message.content;
    let text = typeof content === "string" ? content : content.filter((part: any) => part.type === "text").map((part: any) => part.text).join("\n");
    const ambient: string[] = [];
    text = text.replace(/^<context>\n[\s\S]*?<\/context>\s*/, (block: string) => { ambient.push(block); return ""; });
    text = text.replace(/<live_transcript(?: source="dahlia")?>[\s\S]*?<\/live_transcript>/g, (block: string) => { ambient.push(block); return ""; });
    const entries = ambient.length === 0 ? [] : [{
      ...entry,
      message: { role: "toolResult", toolName: "dahlia_context", content: [{ type: "text", text: ambient.join("\n") }] },
    }];
    return [...entries, { ...entry, message: { ...entry.message, content: text } }];
  });
}

export async function reviewMCP(ctx: any, toolName: string, input: unknown, model = "") {
  // Upstream's extension caps calls before `review`; importing that function requires the same whole-call bound.
  if (JSON.stringify({ tool: toolName, input }, null, 2).length > 128_000) {
    return { outcome: "deny", risk: "unknown", reason: "This MCP call is too large for AI review." };
  }
  const context = {
    ...ctx,
    sessionManager: { getBranch: () => reviewBranch(ctx.sessionManager.getBranch()) },
  };
  try {
    // A model enabled in Settings after this chat started is not in Pi's in-memory catalogue yet.
    if (model) {
      const slash = model.indexOf("/");
      if (!ctx.modelRegistry.find(model.slice(0, slash), model.slice(slash + 1))) await ctx.modelRegistry.refresh();
    }
    // MCP mutations always use the reviewer, without the optional triage classifier.
    // Upstream chooses the model synchronously before its first await. Restore the environment immediately so
    // overlapping reviews and other tools never inherit this call's model selection.
    const previous = process.env.PI_AUTO_REVIEW_MODEL;
    let pending;
    try {
      process.env.PI_AUTO_REVIEW_MODEL = model || `${ctx.model.provider}/${ctx.model.id}`;
      pending = review(context, toolName, input, { triage: false });
    } finally {
      if (previous === undefined) delete process.env.PI_AUTO_REVIEW_MODEL;
      else process.env.PI_AUTO_REVIEW_MODEL = previous;
    }
    return await pending;
  } catch {
    return { outcome: "deny", risk: "unknown", reason: "MCP AI review failed." };
  }
}

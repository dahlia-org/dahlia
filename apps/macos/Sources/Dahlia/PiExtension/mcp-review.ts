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

type TriageConfiguration = { model: string; endpoint: string; provider: string };

export function reviewerEffort(model: any): "low" | "high" {
  const { input, output } = model?.cost ?? {};
  // Pi prices are USD per million tokens. Zero often means unknown (for example, subscriptions).
  if ([input, output].every((price) => Number.isFinite(price) && price > 0)) {
    return input >= 2 || output >= 10 ? "low" : "high";
  }
  return "high";
}

export async function reviewMCP(ctx: any, toolName: string, input: unknown, model = "", configuration?: TriageConfiguration | null) {
  // Upstream's extension caps calls before `review`; importing that function requires the same whole-call bound.
  if (JSON.stringify({ tool: toolName, input }, null, 2).length > 128_000) {
    return { outcome: "deny", risk: "unknown", reason: "This MCP call is too large for AI review." };
  }
  const context = {
    ...ctx,
    sessionManager: { getBranch: () => reviewBranch(ctx.sessionManager.getBranch()) },
  };
  try {
    let triage: Record<string, unknown> | undefined;
    if (configuration?.model === "system.ai.openjev-qwen35-4b") {
      try {
        const apiKey = await ctx.modelRegistry.getApiKeyForProvider(configuration.provider);
        if (apiKey) triage = {
          enabled: true, model: configuration.model, endpoint: configuration.endpoint,
          apiKey, confidence: 0.85, tools: [toolName],
        };
      } catch {
        // Missing or expired classifier credentials leave this action to the reviewer.
      }
    }
    // A model enabled in Settings after this chat started is not in Pi's in-memory catalogue yet.
    let selected = ctx.model;
    if (model) {
      const slash = model.indexOf("/");
      selected = ctx.modelRegistry.find(model.slice(0, slash), model.slice(slash + 1));
      if (!selected) {
        await ctx.modelRegistry.refresh();
        selected = ctx.modelRegistry.find(model.slice(0, slash), model.slice(slash + 1));
      }
    }
    // Dahlia owns triage settings; inherited Pi settings must not enable a different classifier or threshold.
    // Upstream chooses the model synchronously before its first await. Restore the environment immediately so
    // overlapping reviews and other tools never inherit this call's model selection.
    const previous = process.env.PI_AUTO_REVIEW_MODEL;
    let pending;
    try {
      process.env.PI_AUTO_REVIEW_MODEL = model || `${ctx.model.provider}/${ctx.model.id}`;
      pending = review(context, toolName, input, { settings: { triage, effort: reviewerEffort(selected) } });
    } finally {
      if (previous === undefined) delete process.env.PI_AUTO_REVIEW_MODEL;
      else process.env.PI_AUTO_REVIEW_MODEL = previous;
    }
    return await pending;
  } catch {
    return { outcome: "deny", risk: "unknown", reason: "MCP AI review failed." };
  }
}

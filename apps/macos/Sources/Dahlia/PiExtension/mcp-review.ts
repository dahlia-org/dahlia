import { review } from "./pi-auto-review/index.ts";

// Ambient context and other agents' requests cannot confer direct user authorization for MCP mutations.
export function reviewBranch(branch: any[]): any[] {
  return branch.flatMap((entry) => {
    if (entry.type !== "message" || entry.message.role !== "user") return [entry];
    const content = entry.message.content;
    let text = typeof content === "string" ? content : content.filter((part: any) => part.type === "text").map((part: any) => part.text).join("\n");
    const ambient: string[] = [];
    text = text.replace(/^<context>\n[\s\S]*?<\/context>\s*/, (block: string) => { ambient.push(block); return ""; });
    text = text.replace(/<thread_request source="dahlia" untrusted="true">[\s\S]*?<\/thread_request>/g, (block: string) => { ambient.push(block); return ""; });
    text = text.replace(/<thread_results source="dahlia" untrusted="true">[\s\S]*?<\/thread_results>/g, (block: string) => { ambient.push(block); return ""; });
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
  const context = {
    ...ctx,
    sessionManager: { getBranch: () => reviewBranch(ctx.sessionManager.getBranch()) },
    modelRegistry: {
      find: (provider: string, id: string) => ctx.modelRegistry.find(provider, id),
      streamSimple: (selected: any, prompt: any, options: any) => {
        // Count the complete request, including policy and history. UTF-8 bytes conservatively bound text tokens.
        // Codex also budgets by the selected model's window, using 128k tokens when it is unknown.
        const window = selected.contextWindow > 0 ? selected.contextWindow : 128_000;
        const output = selected.maxTokens > 0 ? selected.maxTokens : 16_384;
        const inputBudget = Math.max(0, Math.floor(window * 0.95) - output);
        if (Buffer.byteLength(JSON.stringify(prompt), "utf8") > inputBudget) {
          throw new Error("This request exceeds the reviewer model's context window budget; manual approval is required.");
        }
        return ctx.modelRegistry.streamSimple(selected, prompt, options);
      },
    },
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

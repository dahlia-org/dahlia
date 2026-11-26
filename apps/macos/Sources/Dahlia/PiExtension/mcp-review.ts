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
  const context = { ...ctx, sessionManager: { getBranch: () => reviewBranch(ctx.sessionManager.getBranch()) } };
  try {
    // The bundled pi-auto-review; Dahlia imports only `review`, and Pi never loads its extension.
    const { review, configured } = await import(process.env.DAHLIA_PI_AUTO_REVIEW ?? "");
    // Earlier versions ignore options.settings; never review with a model or classifier the host did not choose.
    if (typeof configured !== "function") throw new Error("The bundled pi-auto-review does not support host settings.");
    let triage: Record<string, unknown> | undefined;
    if (configuration?.model === "system.ai.openjev-qwen35-4b") {
      try {
        const apiKey = await ctx.modelRegistry.getApiKeyForProvider(configuration.provider);
        // Upstream's default threshold for OpenJev is 0.85.
        if (apiKey) triage = { enabled: true, model: configuration.model, endpoint: configuration.endpoint, apiKey, tools: [toolName] };
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
    // Dahlia owns these settings: null keeps PI_AUTO_REVIEW_MODEL and the account's autoReview from choosing the
    // reviewer or turning on a different classifier or threshold.
    return await review(context, toolName, input, {
      settings: { model: model || null, effort: reviewerEffort(selected), triage: triage ?? null },
    });
  } catch {
    return { outcome: "deny", risk: "unknown", reason: "MCP AI review failed." };
  }
}

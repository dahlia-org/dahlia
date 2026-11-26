// pi-mcp-elicitation: Pi's MCP support with URL mode elicitation (MCP 2025-11-25). A server can send the user to a web
// page, for example to sign in to a third-party service or to approve a call, with `elicitation/create` or by failing a
// request with URLElicitationRequiredError (-32042). The user sees the full URL and decides; nothing opens without
// consent. When the user has finished on the page, a request that failed this way is sent again.
import { createMcpExtension } from "@earendil-works/pi-coding-agent";
import { existsSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { type ElicitationPrompt, withElicitation } from "./elicitation.ts";
import { openInBrowser } from "./browser.ts";

export { pageURL, URL_ELICITATION_REQUIRED, withElicitation, type ElicitationPrompt } from "./elicitation.ts";

/** Pi's npm package ships its MCP runtime unbundled beside the entry point; a compiled Pi binary does not. */
async function loadRuntime(): Promise<any> {
  try {
    let directory = dirname(realpathSync(process.argv[1] ?? ""));
    for (;;) {
      const file = join(directory, "dist/extensions/mcp/runtime.js");
      if (existsSync(file)) return await import(pathToFileURL(file).href);
      if (dirname(directory) === directory) return undefined;
      directory = dirname(directory);
    }
  } catch {
    return undefined;
  }
}

export type Confirm = (context: any, title: string, message: string, signal?: AbortSignal) => Promise<boolean>;

/** Hosts can inject a UI adapter that carries cancellation across their own process boundary. */
export function createMCPElicitationExtension(options: { confirm?: Confirm } = {}) {
  return async function (pi: any) {
    let context: any;
    pi.on("session_start", (_event: any, ctx: any) => {
      context = ctx;
    });
    const runtime = await loadRuntime();
    if (!runtime?.createDefaultTransport) {
      // MCP keeps working as Pi's own does; only elicitation is missing.
      pi.on("session_start", (_event: any, ctx: any) => {
        ctx.ui.notify("pi-mcp-elicitation needs Pi installed from npm; MCP elicitation is off.", "warning");
      });
      return createMcpExtension()(pi);
    }
    const confirm: Confirm = options.confirm ?? (async (ctx, title, message, signal) =>
      ctx?.hasUI && (await ctx.ui.confirm(title, message, { signal })) === true);
    // Without a UI nobody can consent, so every page is declined.
    const prompt: ElicitationPrompt = {
      open: async (server, url, message, signal) => (await confirm(
        context,
        `MCP server "${server}" asks you to open ${url.host}`,
        `${message ? `${message}\n\n` : ""}${url.href}`,
        signal,
      )) === true,
      finished: async (server, url, signal) => (await confirm(
        context,
        `Finished on ${url.host}?`,
        `Continue sends the request to MCP server "${server}" again.`,
        signal,
      )) === true,
    };
    return createMcpExtension({
      createTransport: (entry: any, cwd: string, authProvider: any) =>
        withElicitation(runtime.createDefaultTransport(entry, cwd, authProvider), entry.name, prompt, openInBrowser),
    })(pi);
  };
}

export default createMCPElicitationExtension();

import { readFileSync } from "node:fs";

// The schema descriptions and shapes are vendored from the pinned Hermes commit.
export function registerLearningTools(pi: any, bridge: any, approve: any, mcpExtension = "builtin:mcp") {
  const schemas = JSON.parse(readFileSync(new URL("./hermes/tools.json", import.meta.url), "utf8"));
  for (const schema of schemas) {
    pi.registerTool({
      ...schema,
      label: schema.name,
      execute: async (_id: string, args: any, _signal: AbortSignal, _update: unknown, ctx: any) => {
        if (schema.name === "cronjob") {
          const servers = new Set(JSON.parse(process.env.DAHLIA_PI_MCP_SERVERS ?? "[]"));
          const tools = pi.getAllTools().filter((tool: any) => {
            const server = tool.sourceInfo?.path === mcpExtension ? tool.namespace?.aliases?.[0] : undefined;
            return servers.has(server) && (server === "dahlia" ? /^mcp__dahlia__(get|query|list|search)_/.test(tool.name) : tool.annotations?.readOnlyHint === true);
          }).map((tool: any) => tool.name);
          args = { ...args, _readOnlyTools: tools };
        }
        let result = await bridge(ctx, schema.name, args);
        if (schema.name === "cronjob" && result?.approval && result?.request_id) {
          // Dahlia freezes the effective revision before review and commits that exact request once.
          const blocked = await approve(ctx, "cronjob", result.approval, true);
          result = await bridge(ctx, "cronjobCommit", { request_id: result.request_id, approved: !blocked && !ctx.signal?.aborted });
          if (blocked) return { isError: true, content: [{ type: "text", text: blocked.reason }] };
        }
        return { content: [{ type: "text", text: JSON.stringify(result) }] };
      },
    });
  }
}
export const learningTools = ["memory", "skills_list", "skill_view", "skill_manage", "cronjob", "skill_optimize"];

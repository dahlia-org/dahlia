import { readFileSync } from "node:fs";

// The schema descriptions and shapes are vendored from the pinned Hermes commit.
export function registerLearningTools(pi: any, bridge: any) {
  const schemas = JSON.parse(readFileSync(new URL("./hermes/tools.json", import.meta.url), "utf8"));
  for (const schema of schemas) {
    pi.registerTool({
      ...schema,
      label: schema.name,
      execute: async (_id: string, args: any, _signal: AbortSignal, _update: unknown, ctx: any) => {
        if (schema.name === "cronjob") {
          const servers = new Set(JSON.parse(process.env.DAHLIA_PI_MCP_SERVERS ?? "[]"));
          const tools = pi.getAllTools().filter((tool: any) => {
            const server = tool.sourceInfo?.path === "builtin:mcp" ? tool.namespace?.aliases?.[0] : undefined;
            return servers.has(server) && (server === "dahlia" ? /^mcp__dahlia__(get|query|list|search)_/.test(tool.name) : tool.annotations?.readOnlyHint === true);
          }).map((tool: any) => tool.name);
          args = { ...args, _readOnlyTools: tools };
        }
        return { content: [{ type: "text", text: JSON.stringify(await bridge(ctx, schema.name, args)) }] };
      },
    });
  }
}
export const learningTools = ["memory", "skills_list", "skill_view", "skill_manage", "cronjob"];

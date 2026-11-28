/** Pi's tools that list and read the resources of connected MCP servers (Codex's names). */
export const mcpResourceTools = ["list_mcp_resources", "read_mcp_resource"];

/**
 * Whether an interactive chat may run a resource tool. Reading is read-only, like a `readOnlyHint` tool, so it needs no
 * approval, but both operations require an explicit server from Dahlia's snapshot. Pi can also connect servers from
 * a trusted project's configuration, so an unscoped listing must never run.
 */
export function allowsMcpResourceTool(name: string, input: any, servers: Set<string>): boolean {
  const server = input?.server;
  return mcpResourceTools.includes(name) && typeof server === "string" && servers.has(server);
}

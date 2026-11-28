/** Pi's tools that list and read the resources of connected MCP servers (Codex's names). */
export const mcpResourceTools = ["list_mcp_resources", "read_mcp_resource"];

/**
 * Whether an interactive chat may run a resource tool. Reading is read-only, like a `readOnlyHint` tool, so it needs no
 * approval, but only the servers Dahlia registered for this chat are reachable. Listing without a server covers only
 * the servers Pi connected, which are the same registered servers.
 */
export function allowsMcpResourceTool(name: string, input: any, servers: Set<string>): boolean {
  const server = input?.server;
  if (name === "list_mcp_resources") return server === undefined || servers.has(server);
  return name === "read_mcp_resource" && typeof server === "string" && servers.has(server);
}

import assert from "node:assert/strict";
import { test } from "node:test";
import { allowsMcpResourceTool } from "../mcp-resources.ts";

test("resource tools reach only the chat's registered MCP servers", () => {
  const servers = new Set(["dahlia", "gmail"]);
  assert.equal(allowsMcpResourceTool("list_mcp_resources", {}, servers), true);
  assert.equal(allowsMcpResourceTool("list_mcp_resources", { server: "gmail" }, servers), true);
  assert.equal(allowsMcpResourceTool("list_mcp_resources", { server: "foreign" }, servers), false);
  assert.equal(allowsMcpResourceTool("read_mcp_resource", { server: "dahlia", uri: "skill://dahlia/meeting-search/SKILL.md" }, servers), true);
  assert.equal(allowsMcpResourceTool("read_mcp_resource", { server: "foreign", uri: "x" }, servers), false);
  assert.equal(allowsMcpResourceTool("read_mcp_resource", { uri: "x" }, servers), false);
  assert.equal(allowsMcpResourceTool("list_mcp_resource_templates", {}, servers), false);
});

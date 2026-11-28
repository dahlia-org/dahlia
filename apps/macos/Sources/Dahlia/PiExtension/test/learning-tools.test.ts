import assert from "node:assert/strict";
import { test } from "node:test";
import { registerLearningTools } from "../learning-tools.ts";

test("schedule grants use the active MCP source and retain builtin compatibility", async () => {
  const previous = process.env.DAHLIA_PI_MCP_SERVERS;
  process.env.DAHLIA_PI_MCP_SERVERS = JSON.stringify(["gmail", "dahlia"]);
  try {
    for (const source of [undefined, "/extensions/dahlia-mcp.ts"]) {
      const path = source ?? "builtin:mcp";
      const tool = (name: string, server = "gmail", readOnlyHint = true, origin = path) => ({
        name, sourceInfo: { path: origin }, namespace: { aliases: [server] }, annotations: { readOnlyHint },
      });
      const registered: any[] = [];
      const payloads: any[] = [];
      registerLearningTools({
        registerTool: (entry: any) => registered.push(entry),
        getAllTools: () => [
          tool("mcp__gmail__search"), tool("mcp__gmail__send", "gmail", false),
          tool("mcp__foreign__search", "foreign"), tool("imposter", "gmail", true, "/other.ts"),
          tool("mcp__dahlia__get_meetings", "dahlia"), tool("mcp__dahlia__delete_meeting", "dahlia"),
        ],
      }, async (_ctx: any, _method: string, payload: any) => { payloads.push(payload); return {}; }, async () => {}, source);
      for (const action of ["create", "update", "resume"]) {
        await registered.find((entry) => entry.name === "cronjob").execute("call", { action }, undefined, undefined, {});
      }
      for (const payload of payloads) {
        assert.deepEqual(payload._readOnlyTools, ["mcp__gmail__search", "mcp__dahlia__get_meetings"]);
      }
    }
  } finally {
    if (previous === undefined) delete process.env.DAHLIA_PI_MCP_SERVERS;
    else process.env.DAHLIA_PI_MCP_SERVERS = previous;
  }
});

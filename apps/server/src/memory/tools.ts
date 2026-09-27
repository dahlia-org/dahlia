import { createTool } from "@mastra/core/tools";
import { z } from "zod";
import { meetingContext, publicIdSchema, withMcpInputSchema } from "../agent/tools";
import { RequestError } from "../storage/upload";
import { decodeId } from "../typeid";
import type { WorkspaceMemoryService } from "./service";
import { HindsightError } from "./hindsight";
import { memorySearchOptions } from "./dahlia";

export function createMemoryTools(memory: WorkspaceMemoryService) {
  const { project, after, before, depth } = memorySearchOptions;
  const base = { workspace_id: publicIdSchema("workspace"), query: z.string().min(1).max(4000) };
  // Strict agent tools require every property, so omitted MCP options arrive as null.
  const schema = z.object({ ...base, project_id: project.nullable(), after: after.nullable(), before: before.nullable(), depth: depth.nullable() }).strict();
  const mcpSchema = z.object({ ...base, project_id: project.optional(), after: after.optional(), before: before.optional(), depth: depth.optional() }).strict();
  const tool = (reflect: boolean) => withMcpInputSchema(createTool({
    id: reflect ? "reflect_workspace_memory" : "recall_workspace_memory", strict: true,
    description: reflect ? "Find cross-meeting insights in the selected Workspace. Only returned canonical Dahlia sources are evidence; hypotheses need verification. With after/before, returns period-ranked recall sources only and no hypothesis."
      : "Find relevant past meetings and shared notes in the selected Workspace, with verified canonical Dahlia excerpts.",
    inputSchema: schema,
    mcp: { annotations: { readOnlyHint: true } },
    execute: async ({ workspace_id, query, ...input }, context) => {
      const { identity, workspaceId, authorize } = meetingContext(context.requestContext, workspace_id);
      const signal = context.abortSignal ?? new AbortController().signal;
      try {
        await authorize?.();
        const result = await memory.search(identity, workspaceId, query, reflect, signal, {
          projectId: input.project_id ? decodeId("project", input.project_id) : undefined,
          after: input.after ?? undefined, before: input.before ?? undefined, depth: input.depth ?? undefined });
        await authorize?.();
        return result;
      }
      catch (error) {
        const unsupported = error instanceof RequestError && error.status === 409 && error.code === "memory_encrypted_workspace_unsupported";
        if (signal.aborted || (error instanceof RequestError && !unsupported)) throw error;
        return { unavailable: true, code: error instanceof HindsightError || unsupported ? error.code : "memory_unavailable",
          instruction: "Tell the user memory is unavailable; continue with the canonical meeting tools. Never claim there are no relevant meetings based on this failure." };
      }
    },
  }), mcpSchema, (input) => ({ project_id: null, after: null, before: null, depth: null, ...input }));
  return { recall_workspace_memory: tool(false), reflect_workspace_memory: tool(true) };
}

export type MemoryTools = ReturnType<typeof createMemoryTools>;

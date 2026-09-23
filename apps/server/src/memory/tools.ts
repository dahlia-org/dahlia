import { createTool } from "@mastra/core/tools";
import { z } from "zod";
import { meetingContext, publicIdSchema, withMcpInputSchema } from "../agent/tools";
import { RequestError } from "../storage/upload";
import type { WorkspaceMemoryService } from "./service";
import { HindsightError } from "./hindsight";

export function createMemoryTools(memory: WorkspaceMemoryService) {
  const schema = z.object({ workspace_id: publicIdSchema("workspace"), query: z.string().min(1).max(4000) }).strict();
  const tool = (reflect: boolean) => withMcpInputSchema(createTool({
    id: reflect ? "reflect_workspace_memory" : "recall_workspace_memory", strict: true,
    description: reflect ? "Find cross-meeting insights in the selected Workspace. Only returned canonical Dahlia sources are evidence; hypotheses need verification."
      : "Find relevant past meetings and shared notes in the selected Workspace, with verified canonical Dahlia excerpts.",
    inputSchema: schema,
    mcp: { annotations: { readOnlyHint: true } },
    execute: async ({ workspace_id, query }, context) => {
      const { identity, workspaceId, authorize } = meetingContext(context.requestContext, workspace_id);
      const signal = context.abortSignal ?? new AbortController().signal;
      try {
        await authorize?.();
        const result = await memory.search(identity, workspaceId, query, reflect, signal);
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
  }), schema);
  return { recall_workspace_memory: tool(false), reflect_workspace_memory: tool(true) };
}

export type MemoryTools = ReturnType<typeof createMemoryTools>;

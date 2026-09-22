import { createTool } from "@mastra/core/tools";
import { z } from "zod";
import type { Identity } from "../auth/identity";
import type { WorkspaceMemoryService } from "./service";
import { HindsightError } from "./hindsight";

export function createMemoryTools(memory: WorkspaceMemoryService, identity: Identity, workspaceId: string, signal: AbortSignal) {
  const tool = (reflect: boolean) => createTool({
    id: reflect ? "reflect_workspace_memory" : "recall_workspace_memory", strict: true,
    description: reflect ? "Find cross-meeting insights in the selected Workspace. Only returned canonical Dahlia sources are evidence; hypotheses need verification."
      : "Find relevant past meetings and shared notes in the selected Workspace, with verified canonical Dahlia excerpts.",
    inputSchema: z.object({ query: z.string().min(1).max(4000) }).strict(),
    execute: async ({ query }) => {
      try { return await memory.search(identity, workspaceId, query, reflect, signal); }
      catch (error) {
        if (signal.aborted) throw error;
        return { unavailable: true, code: error instanceof HindsightError ? error.code : "memory_unavailable",
          instruction: "Tell the user memory is unavailable; continue with the canonical meeting tools. Never claim there are no relevant meetings based on this failure." };
      }
    },
  });
  return { recall_workspace_memory: tool(false), reflect_workspace_memory: tool(true) };
}

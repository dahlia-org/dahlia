import { askUserTool, createTool, submitPlanTool } from "@mastra/core/tools";
import type { Memory } from "@mastra/memory";
import { z } from "zod";

const runFields = { runId: z.string().min(1).max(200), toolCallId: z.string().min(1).max(200) };
export const aiResumeSchema = z.discriminatedUnion("tool", [
  z.object({ ...runFields, tool: z.literal("ask_user"), answer: z.union([z.string().min(1).max(16_000), z.array(z.string().min(1).max(200)).min(1).max(20)]) }).strict(),
  z.object({ ...runFields, tool: z.literal("submit_plan"), action: z.enum(["approved", "rejected"]), feedback: z.string().max(16_000).optional() }).strict(),
]);
export type AiResume = z.infer<typeof aiResumeSchema>;
const planSchema = z.object({ path: z.string().regex(/^plans\/[a-zA-Z0-9_-]{1,80}\.md$/), title: z.string().min(1).max(200), content: z.string().min(1).max(12_000) }).strict();
const questionSchema = z.object({
  question: z.string(),
  options: z.array(z.object({ label: z.string().min(1).max(200), description: z.string().optional() })).max(20).optional(),
  selectionMode: z.enum(["single_select", "multi_select"]).optional(),
});
export const aiInteractionSchema = z.discriminatedUnion("tool", [
  z.object({ ...runFields, tool: z.literal("ask_user"), ...questionSchema.shape }),
  z.object({ ...runFields, tool: z.literal("submit_plan"), ...planSchema.shape }),
]);
export type AiInteraction = z.infer<typeof aiInteractionSchema>;
export type AgentHistory = { memory: Memory; threadId: string; resourceId: string };

export async function readInteraction(history: AgentHistory): Promise<AiInteraction | undefined> {
  const state = await history.memory.storage.getStore("threadState");
  const value = await state!.getState({ threadId: history.threadId, type: "interaction" });
  return value == null ? undefined : aiInteractionSchema.parse(value);
}
export async function saveInteraction(history: AgentHistory, value: AiInteraction | undefined): Promise<void> {
  const state = await history.memory.storage.getStore("threadState");
  if (value) await state!.setState({ threadId: history.threadId, type: "interaction", value });
  else await state!.deleteState({ threadId: history.threadId, type: "interaction" });
}
export async function readPlan(history: AgentHistory, path: string) {
  const state = await history.memory.storage.getStore("threadState");
  const value = await state!.getState({ threadId: history.threadId, type: "plan" });
  const plan = value == null ? undefined : planSchema.parse(value);
  if (!plan || plan.path !== path) throw new Error("plan_not_found");
  return plan;
}

export function createInteractiveTools(history: AgentHistory) {
  return {
    ask_user: createTool({ id: askUserTool.id, description: askUserTool.description,
      inputSchema: questionSchema, suspendSchema: askUserTool.suspendSchema, resumeSchema: askUserTool.resumeSchema,
      execute: (input, context) => askUserTool.execute!(input, context),
    }),
    submit_plan: createTool({ id: submitPlanTool.id, description: "Submit a plan previously saved with write_plan for the user's approval. Pass its path. Wait for explicit approval before proceeding.",
      inputSchema: planSchema.pick({ path: true }), suspendSchema: submitPlanTool.suspendSchema, resumeSchema: submitPlanTool.resumeSchema,
      execute: async (input, context) => {
        await readPlan(history, input.path);
        return submitPlanTool.execute!(input, context);
      },
    }),
    write_plan: createTool({ id: "write_plan", description: "Save or revise this chat's plan before calling submit_plan. Use a path such as plans/meeting-review.md. This replaces the previous plan; it does not write to the Server filesystem.",
      inputSchema: planSchema, execute: async (plan) => {
        if (await readInteraction(history)) throw new Error("plan_awaiting_response");
        const state = await history.memory.storage.getStore("threadState");
        // ponytail: one plan per chat; add a file collection if parallel plans are needed.
        await state!.setState({ threadId: history.threadId, type: "plan", value: plan });
        return { path: plan.path, saved: true };
      },
    }),
    read_plan: createTool({ id: "read_plan", description: "Read this chat's saved plan.", inputSchema: planSchema.pick({ path: true }),
      execute: ({ path }) => readPlan(history, path),
    }),
  };
}

export async function suspendedInteraction(history: AgentHistory, runId: string, toolCallId: string, toolName: string, payload: unknown): Promise<AiInteraction> {
  if (toolName === "submit_plan") {
    const { path } = z.object({ path: z.string() }).parse(payload);
    return { runId, toolCallId, tool: "submit_plan", ...await readPlan(history, path) };
  }
  if (toolName !== "ask_user") throw new Error("unsupported_tool_suspension");
  return aiInteractionSchema.parse({ runId, toolCallId, tool: "ask_user", ...questionSchema.parse(payload) });
}

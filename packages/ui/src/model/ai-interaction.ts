// Wire shapes of resumable AI chat tools (ask_user, submit_plan), shared by the Server Agent and the chat UI.
import { z } from "zod";

const runFields = { runId: z.string().min(1).max(200), toolCallId: z.string().min(1).max(200) };
export const aiResumeSchema = z.discriminatedUnion("tool", [
  z.object({ ...runFields, tool: z.literal("ask_user"), answer: z.union([z.string().min(1).max(16_000), z.array(z.string().min(1).max(200)).min(1).max(20)]) }).strict(),
  z.object({ ...runFields, tool: z.literal("submit_plan"), action: z.enum(["approved", "rejected"]), feedback: z.string().max(16_000).optional() }).strict(),
]);
export type AiResume = z.infer<typeof aiResumeSchema>;
export const planSchema = z.object({ path: z.string().regex(/^plans\/[a-zA-Z0-9_-]{1,80}\.md$/), title: z.string().min(1).max(200), content: z.string().min(1).max(12_000) }).strict();
export const questionSchema = z.object({
  question: z.string(),
  options: z.array(z.object({ label: z.string().min(1).max(200), description: z.string().optional() })).max(20).optional(),
  selectionMode: z.enum(["single_select", "multi_select"]).optional(),
});
export const aiInteractionSchema = z.discriminatedUnion("tool", [
  z.object({ ...runFields, tool: z.literal("ask_user"), ...questionSchema.shape }),
  z.object({ ...runFields, tool: z.literal("submit_plan"), ...planSchema.shape }),
]);
export type AiInteraction = z.infer<typeof aiInteractionSchema>;

import { z } from "zod";

const geminiResponse = z.object({
  responseId: z.string().optional(), modelVersion: z.string().optional(),
  candidates: z.array(z.object({ finishReason: z.literal("STOP"), content: z.object({
    parts: z.array(z.object({ text: z.string().optional(), thought: z.boolean().optional() })),
  }) })).length(1),
  usageMetadata: z.object({ promptTokenCount: z.number().optional(), candidatesTokenCount: z.number().optional(),
    thoughtsTokenCount: z.number().optional(), totalTokenCount: z.number().optional(), cachedContentTokenCount: z.number().optional(),
  }).optional(),
});

// Normalize the native /ai/run response at the provider boundary; persistence remains shared.
export function geminiChatResponse(body: unknown) {
  const envelope = z.object({ success: z.literal(true), result: z.unknown() }).safeParse(body);
  const parsed = geminiResponse.parse(envelope.success ? envelope.data.result : body);
  const usage = parsed.usageMetadata;
  return {
    id: parsed.responseId, model: parsed.modelVersion,
    choices: [{ finish_reason: "stop", message: { content: parsed.candidates[0]!.content.parts
      .filter((part) => !part.thought).map((part) => part.text ?? "").join("") } }],
    ...(usage ? { usage: { prompt_tokens: usage.promptTokenCount, completion_tokens: usage.candidatesTokenCount,
      reasoning_tokens: usage.thoughtsTokenCount, total_tokens: usage.totalTokenCount,
      prompt_tokens_details: { cached_tokens: usage.cachedContentTokenCount } } } : {}),
  };
}

export function geminiPart(content: Record<string, unknown>): Record<string, unknown> {
  if (content.type === "input_text") return { text: content.text };
  const [, mimeType, data] = /^data:([^;,]+);base64,(.*)$/s.exec(String(content.image_url))!;
  return { inlineData: { mimeType, data } };
}

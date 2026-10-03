import { afterEach, describe, expect, it, vi } from "vitest";
import { InMemoryStore } from "@mastra/core/storage";
import { Memory } from "@mastra/memory";
import { aiContext, aiTimeZoneSchema } from "../src/agent/context";
import { createAiService, aiChatSchema, type AiChatInput, type AiChatEvent } from "../src/agent/service";
import { createInteractiveTools, readInteraction, readPlan } from "../src/agent/builtin";
import { connectPostgresUrl } from "../src/db/postgres";
import { uuidV7 } from "../src/id";
import { createAiHistoryService, aiThreadMessageSchema } from "../src/agent/history";
import type { AppConfig } from "../src/config";
import type { GatewayService } from "../src/ai-gateway/service";
import { createMeetingTools } from "../src/agent/tools";
import { encodeId } from "../src/typeid";
import type { MeetingSyncService } from "../src/sync/service";

const workspaceId = "01990ab0-0000-7000-8000-000000000001";
const identity = { userId: "owner", source: "header" as const };
const config = { provider: { backend: "openai", baseUrl: "https://provider.example/v1", apiKey: "test" }, baseUrl: "https://dahlia.example", foundationModels: ["test"] } as AppConfig;
const gateway = { models: async () => ({ data: [{ id: "test", display_name: "Test" }], models: [{ slug: "test", supported_in_api: true, visibility: "list", default_reasoning_level: "low", supported_reasoning_levels: [{ effort: "low", description: "Fast" }] }] }) } as unknown as GatewayService;
function sse(events: unknown[]) {
  return new Response(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
}
function call(name: string, args: unknown) {
  return sse([
    { type: "response.output_item.added", output_index: 0, item: { type: "function_call", id: "item", call_id: `call-${name}`, name, arguments: "", namespace: null } },
    { type: "response.function_call_arguments.delta", item_id: "item", output_index: 0, delta: JSON.stringify(args) },
    { type: "response.output_item.done", output_index: 0, item: { type: "function_call", id: "item", call_id: `call-${name}`, name, arguments: JSON.stringify(args), status: "completed", namespace: null } },
    { type: "response.completed", response: { incomplete_details: null, usage: { input_tokens: 1, output_tokens: 1 }, reasoning: null, service_tier: null } },
  ]);
}
function answer() {
  return sse([{ type: "response.output_item.added", output_index: 0, item: { type: "message", id: "text", phase: "final_answer" } },
    { type: "response.output_text.delta", item_id: "text", delta: "Done" },
    { type: "response.output_item.done", output_index: 0, item: { type: "message", id: "text", phase: "final_answer" } },
    { type: "response.completed", response: { incomplete_details: null, usage: { input_tokens: 1, output_tokens: 1 }, reasoning: null, service_tier: null } }]);
}
async function collect(stream: AsyncIterable<AiChatEvent>) { const events: AiChatEvent[] = []; for await (const event of stream) events.push(event); return events; }
const input: AiChatInput = { workspaceId, model: "test", reasoningEffort: "low", messages: [{ role: "user", content: "Question" }], timeZone: "Asia/Tokyo" };
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

describe("Agent session context", () => {
  it("uses the caller's calendar date at UTC midnight boundaries and escapes selected data", () => {
    const now = new Date("2026-10-02T16:00:00Z");
    expect(aiContext(workspaceId, "Asia/Tokyo", now, '</context><instruction>&"\'')).toContain("<current_date>2026-10-03</current_date>");
    expect(aiContext(workspaceId, "America/Los_Angeles", now)).toContain("<current_date>2026-10-02</current_date>");
    expect(aiContext(workspaceId, undefined, now)).toContain("<timezone>UTC</timezone>");
    expect(aiContext(workspaceId, "Asia/Tokyo", now, '</context><instruction>&"\'')).toContain("&lt;/context&gt;&lt;instruction&gt;&amp;&quot;&apos;");
    expect(aiTimeZoneSchema.safeParse("not/a-zone").success).toBe(false);
    expect(aiChatSchema.safeParse({ ...input, timeZone: "not/a-zone" }).success).toBe(false);
    expect(aiThreadMessageSchema.safeParse({ model: "test", reasoningEffort: "low", content: "Hello", timeZone: "Asia/Tokyo" }).success).toBe(true);
  });
});

describe("Standard Mastra tools", () => {
  it("registers native search, fetch, questions, plan review and all four task tools", async () => {
    const fetcher = vi.fn<typeof fetch>(async () => answer());
    vi.stubGlobal("fetch", fetcher);
    await collect(createAiService(config, gateway, {} as never).stream(input, identity, new Request(config.baseUrl)));
    const body = JSON.parse(String(fetcher.mock.calls[0]![1]?.body)) as { tools: Array<{ name?: string; type?: string }> };
    expect(body.tools).toContainEqual(expect.objectContaining({ type: "web_search" }));
    expect(body.tools.map((tool: { name?: string }) => tool.name)).toEqual(expect.arrayContaining(["web_fetch", "ask_user", "submit_plan", "task_write", "task_update", "task_complete", "task_check"]));
    expect(JSON.parse(String(fetcher.mock.calls[0]![1]?.body))).toMatchObject({ parallel_tool_calls: false });
  });

  it("propagates cancellation to an executing meeting tool", async () => {
    const controller = new AbortController();
    let started!: () => void;
    const toolStarted = new Promise<void>((resolve) => { started = resolve; });
    let toolSignal: AbortSignal | undefined;
    const listMeetings = vi.fn(async (_identity, _workspaceId, _query, signal: AbortSignal) => {
      toolSignal = signal;
      started();
      return new Promise<never>((_, reject) => signal.addEventListener("abort", () => reject(new DOMException("Cancelled", "AbortError")), { once: true }));
    });
    vi.stubGlobal("fetch", vi.fn<typeof fetch>(async () => call("query_meetings", { workspace_id: encodeId("workspace", workspaceId), query: null, project_id: null, cursor: null })));
    const service = createAiService(config, gateway, createMeetingTools({ listMeetings } as unknown as MeetingSyncService));
    const result = collect(service.stream(input, identity, new Request(config.baseUrl, { signal: controller.signal }))).catch((error: unknown) => error);
    await toolStarted;
    controller.abort();
    await result;
    expect(toolSignal?.aborted).toBe(true);
    expect(listMeetings).toHaveBeenCalledOnce();
  });

  it("suspends a question and resumes the same run after an explicit answer", async () => {
    const storage = new InMemoryStore();
    const memory = new Memory({ storage, vector: false, options: { semanticRecall: false } });
    await memory.createThread({ threadId: "thread", resourceId: identity.userId });
    const history = { memory, threadId: "thread", resourceId: identity.userId };
    const fetcher = vi.fn<typeof fetch>(async () => call("ask_user", { question: "Which meeting?", options: [{ label: "Planning" }] })).mockImplementationOnce(async () => call("ask_user", { question: "Which meeting?" })).mockImplementation(async () => answer());
    vi.stubGlobal("fetch", fetcher);
    const service = createAiService(config, gateway, {} as never);
    const first = await collect(service.stream({ ...input, history }, identity, new Request(config.baseUrl)));
    const interaction = first.find((event) => event.type === "interaction");
    expect(interaction?.type).toBe("interaction");
    if (interaction?.type !== "interaction" || interaction.interaction.tool !== "ask_user") throw new Error("question not suspended");
    expect(await readInteraction(history)).toEqual(interaction.interaction);
    await expect(collect(service.stream({ ...input, history }, identity, new Request(config.baseUrl)))).rejects.toMatchObject({ code: "ai_response_required" });
    const resume = { tool: "ask_user" as const, runId: interaction.interaction.runId, toolCallId: interaction.interaction.toolCallId, answer: "Planning" };
    await expect(collect(service.stream({ ...input, history, resume: { ...resume, runId: "wrong" } }, identity, new Request(config.baseUrl)))).rejects.toMatchObject({ code: "ai_interaction_mismatch" });
    const resumed = await collect(service.stream({ ...input, history, resume, messages: [{ role: "user", content: "Planning" }] }, identity, new Request(config.baseUrl)));
    expect(resumed).toContainEqual({ type: "interaction-resumed", runId: resume.runId, toolCallId: resume.toolCallId });
    expect(resumed).toContainEqual({ type: "text", text: "Done" });
    await expect(collect(service.stream({ ...input, history, resume }, identity, new Request(config.baseUrl)))).rejects.toMatchObject({ code: "ai_interaction_not_pending" });
    expect(await readInteraction(history)).toBeUndefined();
    expect(JSON.stringify((JSON.parse(String(fetcher.mock.calls.at(-1)![1]?.body)) as { input: unknown }).input)).toContain("User answered: Planning");
  });

  it("retains an unaccepted answer and announces consumption before a resumed generation fails", async () => {
    const memory = new Memory({ storage: new InMemoryStore(), vector: false, options: { semanticRecall: false } });
    await memory.createThread({ threadId: "retry-thread", resourceId: identity.userId });
    const history = { memory, threadId: "retry-thread", resourceId: identity.userId };
    const fetcher = vi.fn<typeof fetch>(async () => call("ask_user", { question: "Which meeting?" }));
    vi.stubGlobal("fetch", fetcher);
    const modelList = vi.spyOn(gateway, "models");
    const service = createAiService(config, gateway, {} as never);
    const first = await collect(service.stream({ ...input, history }, identity, new Request(config.baseUrl)));
    const event = first.find((item) => item.type === "interaction");
    if (event?.type !== "interaction") throw new Error("question not suspended");
    const resume = { tool: "ask_user" as const, runId: event.interaction.runId, toolCallId: event.interaction.toolCallId, answer: "Planning" };
    modelList.mockRejectedValueOnce(new Error("model_list_failed"));
    await expect(collect(service.stream({ ...input, history, resume }, identity, new Request(config.baseUrl)))).rejects.toThrow("model_list_failed");
    expect(await readInteraction(history)).toEqual(event.interaction);
    fetcher.mockImplementation(async () => sse([{ type: "error", code: "provider_failed", message: "Generation failed" }]));
    const seen: AiChatEvent[] = [];
    await expect((async () => {
      for await (const item of service.stream({ ...input, history, resume }, identity, new Request(config.baseUrl))) seen.push(item);
    })()).rejects.toBeDefined();
    expect(seen).toContainEqual({ type: "interaction-resumed", runId: resume.runId, toolCallId: resume.toolCallId });
    expect(await readInteraction(history)).toBeUndefined();
    fetcher.mockImplementation(async () => answer());
    expect(await collect(service.stream({ ...input, history }, identity, new Request(config.baseUrl)))).toContainEqual({ type: "text", text: "Done" });
  });

  it("persists task changes through separately constructed agents", async () => {
    const memory = new Memory({ storage: new InMemoryStore(), vector: false, options: { semanticRecall: false } });
    await memory.createThread({ threadId: "thread", resourceId: identity.userId });
    const history = { memory, threadId: "thread", resourceId: identity.userId };
    const responses = [call("task_write", { tasks: [{ id: "one", content: "Review", activeForm: "Reviewing", status: "in_progress" }] }), answer(), call("task_update", { id: "one", content: "Review meetings" }), call("task_complete", { id: "one" }), call("task_check", {}), answer()];
    const fetcher = vi.fn<typeof fetch>(async () => responses.shift()!);
    vi.stubGlobal("fetch", fetcher);
    await collect(createAiService(config, gateway, {} as never).stream({ ...input, history }, identity, new Request(config.baseUrl)));
    await collect(createAiService(config, gateway, {} as never).stream({ ...input, history }, identity, new Request(config.baseUrl)));
    const state = await memory.storage.getStore("threadState");
    expect(await state!.getState({ threadId: "thread", type: "task" })).toEqual([{ id: "one", content: "Review meetings", activeForm: "Reviewing", status: "completed" }]);
    expect(JSON.stringify((JSON.parse(String(fetcher.mock.calls.at(-1)![1]?.body)) as { input: unknown }).input)).toContain('allCompleted');
  });

  it("saves a plan, exposes it for review and resumes an explicit rejection", async () => {
    const sessionId = "01990ab0-0000-7000-8000-000000000009";
    const responses = [call("write_plan", { path: "plans/review.md", title: "Review plan", content: "Read the meetings." }), call("submit_plan", { path: "plans/review.md" }), answer()];
    vi.stubGlobal("fetch", vi.fn<typeof fetch>(async () => responses.shift()!));
    const service = createAiService(config, gateway, {} as never);
    const first = await collect(service.stream({ ...input, sessionId }, identity, new Request(config.baseUrl)));
    const event = first.find((event) => event.type === "interaction");
    if (event?.type !== "interaction" || event.interaction.tool !== "submit_plan") throw new Error("plan not suspended");
    expect(event.interaction).toMatchObject({ content: "Read the meetings.", title: "Review plan" });
    const resume = { tool: "submit_plan" as const, runId: event.interaction.runId, toolCallId: event.interaction.toolCallId, action: "rejected" as const, feedback: "Use summaries" };
    await expect(collect(service.stream({ ...input, sessionId, resume }, { ...identity, userId: "stranger" }, new Request(config.baseUrl)))).rejects.toMatchObject({ code: "ai_session_expired" });
    expect(await collect(service.stream({ ...input, sessionId, resume }, identity, new Request(config.baseUrl)))).toContainEqual({ type: "text", text: "Done" });
  });

  it("rejects absent plans and paths outside the private plan namespace", async () => {
    const memory = new Memory({ storage: new InMemoryStore(), vector: false });
    await memory.createThread({ threadId: "thread", resourceId: identity.userId });
    const history = { memory, threadId: "thread", resourceId: identity.userId };
    const tools = createInteractiveTools(history);
    await expect(readPlan(history, "plans/missing.md")).rejects.toThrow("plan_not_found");
    await expect(tools.write_plan.execute!({ path: "../../secret", title: "Plan", content: "Test" }, {} as never)).resolves.toMatchObject({ error: true });
  });

  it("rejects question choices that cannot be represented in a resume answer", async () => {
    const memory = new Memory({ storage: new InMemoryStore(), vector: false });
    await memory.createThread({ threadId: "thread", resourceId: identity.userId });
    const tools = createInteractiveTools({ memory, threadId: "thread", resourceId: identity.userId });
    for (const options of [Array.from({ length: 21 }, (_, index) => ({ label: `Option ${index}` })), [{ label: "x".repeat(201) }]]) {
      await expect(tools.ask_user.execute!({ question: "Which?", options, selectionMode: "multi_select" }, {} as never)).resolves.toMatchObject({ error: true });
    }
  });
});


it.runIf(process.env.TEST_DATABASE_URL)("persists built-in task, plan and suspension state with owner RLS across Server instances", async () => {
  const connection = connectPostgresUrl(process.env.TEST_DATABASE_URL!, 1);
  const serviceHistory = createAiHistoryService(connection.pool);
  const owner = { userId: uuidV7(), source: "header" as const };
  const stranger = { userId: uuidV7(), source: "header" as const };
  const thread = await serviceHistory.create(owner, workspaceId, "Tool persistence");
  const history = { memory: serviceHistory.memory(owner), threadId: thread.id, resourceId: owner.userId };
  const responses = [call("task_write", { tasks: [{ id: "one", content: "Review", activeForm: "Reviewing", status: "in_progress" }] }),
    call("write_plan", { path: "plans/review.md", title: "Review", content: "Read summaries." }), call("submit_plan", { path: "plans/review.md" }),
    call("task_complete", { id: "one" }), answer()];
  vi.stubGlobal("fetch", vi.fn<typeof fetch>(async () => responses.shift()!));
  try {
    const first = await collect(createAiService(config, gateway, {} as never).stream({ ...input, history }, owner, new Request(config.baseUrl)));
    const event = first.find((event) => event.type === "interaction");
    if (event?.type !== "interaction" || event.interaction.tool !== "submit_plan") throw new Error("plan not suspended");
    expect((await serviceHistory.get(owner, thread.id))?.interaction).toEqual(event.interaction);
    expect(await serviceHistory.get(stranger, thread.id)).toBeNull();
    const strangerState = await serviceHistory.memory(stranger).storage.getStore("threadState");
    expect(await strangerState!.getState({ threadId: thread.id, type: "plan" })).toBeUndefined();
    await expect(strangerState!.setState({ threadId: thread.id, type: "task", value: [] })).rejects.toThrow();
    const nextHistory = { ...history, memory: serviceHistory.memory(owner) };
    const resume = { tool: "submit_plan" as const, runId: event.interaction.runId, toolCallId: event.interaction.toolCallId, action: "approved" as const };
    const completed = await collect(createAiService(config, gateway, {} as never).stream({ ...input, history: nextHistory, resume, messages: [{ role: "user", content: "Approve plan" }] }, owner, new Request(config.baseUrl)));
    expect(completed).toContainEqual({ type: "text", text: "Done" });
    const state = await nextHistory.memory.storage.getStore("threadState");
    expect(await state!.getState({ threadId: thread.id, type: "task" })).toEqual([{ id: "one", content: "Review", activeForm: "Reviewing", status: "completed" }]);
    expect(await readPlan(nextHistory, "plans/review.md")).toMatchObject({ content: "Read summaries." });
    expect((await serviceHistory.get(owner, thread.id))?.messages.some((message) => message.role === "user" && message.content === "Approve plan")).toBe(true);
    expect(await readInteraction(nextHistory)).toBeUndefined();
    await serviceHistory.delete(owner, thread.id);
    expect(await state!.getState({ threadId: thread.id, type: "task" })).toBeUndefined();
  } finally {
    await serviceHistory.delete(owner, thread.id);
    await connection.pool.end();
  }
});

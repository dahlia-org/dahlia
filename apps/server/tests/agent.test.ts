import { describe, expect, it, vi } from "vitest";

import { aiChatSchema, createAiService } from "../src/agent/service";
import { createMeetingTools, meetingRequestContext } from "../src/agent/tools";
import { registerMastraTool } from "../src/mcp";
import { encodeId } from "../src/typeid";
import type { Identity } from "../src/auth/identity";
import type { MeetingSyncService } from "../src/sync/service";
import { mergeRecoveredMessages, prependEarlierMessages, readAiEvents, recoverFailedDraft } from "../src/client/AiChat";
import type { AppConfig } from "../src/config";
import type { GatewayService } from "../src/ai-gateway/service";

const workspaceId = "01990ab0-0000-7000-8000-000000000001";
const otherWorkspaceId = "01990ab0-0000-7000-8000-000000000002";
const identity: Identity = { userId: "user", source: "header" };

function responsesStream(...events: unknown[]) {
  return new Response(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n", {
    headers: { "content-type": "text/event-stream" },
  });
}

describe("Mastra meeting tools", () => {
  it("enforces the AI-fixed Workspace before calling MeetingSyncService", async () => {
    const listMeetings = vi.fn().mockResolvedValue({ items: [], nextCursor: null });
    const tools = createMeetingTools({ listMeetings } as unknown as MeetingSyncService);
    await expect(tools.query_meetings.execute!({
      workspace_id: encodeId("workspace", otherWorkspaceId), query: null, project_id: null, cursor: null,
    }, {
      requestContext: meetingRequestContext(identity, workspaceId),
    } as never)).rejects.toMatchObject({ status: 403, code: "workspace_scope_mismatch" });
    expect(listMeetings).not.toHaveBeenCalled();
  });

  it("ignores Luna placeholder optionals only in the AI-fixed scope", async () => {
    const listMeetings = vi.fn().mockResolvedValue({ items: [] });
    const listTranscript = vi.fn().mockResolvedValue({ items: [] });
    const getProject = vi.fn().mockResolvedValue(null);
    const tools = createMeetingTools({ getProject, listMeetings, listTranscript } as unknown as MeetingSyncService);
    await tools.query_meetings.execute!({
      workspace_id: encodeId("workspace", workspaceId),
      query: "",
      project_id: encodeId("project", otherWorkspaceId),
      cursor: "",
    }, { requestContext: meetingRequestContext(identity, workspaceId) } as never);
    expect(getProject).toHaveBeenCalledWith(identity, workspaceId, otherWorkspaceId);
    expect(listMeetings).toHaveBeenCalledWith(identity, workspaceId, undefined, undefined, undefined, undefined);
    await tools.get_meeting_transcript.execute!({
      workspace_id: encodeId("workspace", workspaceId), meeting_id: encodeId("meeting", workspaceId),
      cursor: "", after: "", wait: false,
    }, { requestContext: meetingRequestContext(identity, workspaceId) } as never);
    expect(listTranscript).toHaveBeenCalledWith(identity, workspaceId, workspaceId, undefined,
      expect.objectContaining({ after: undefined, wait: false }));
    await expect(tools.query_meetings.execute!({
      workspace_id: encodeId("workspace", workspaceId), query: null, project_id: null, cursor: "",
    }, { requestContext: meetingRequestContext(identity) } as never)).rejects.toThrow("invalid_cursor");
    await expect(tools.get_meeting_transcript.execute!({
      workspace_id: encodeId("workspace", workspaceId), meeting_id: encodeId("meeting", workspaceId),
      cursor: "", after: undefined, wait: false,
    } as never, { requestContext: meetingRequestContext(identity) } as never)).rejects.toThrow("invalid_cursor");
  });

  it("registers and executes the same Mastra tool object through the MCP adapter", async () => {
    const listMeetings = vi.fn().mockResolvedValue({ items: [], nextCursor: null });
    const tool = createMeetingTools({ listMeetings } as unknown as MeetingSyncService).query_meetings;
    const signal = new AbortController().signal;
    let registered: { name: string; options: { inputSchema: unknown }; handler: (input: unknown, context: unknown) => Promise<unknown> } | undefined;
    const server = { registerTool(name: string, options: { inputSchema: unknown }, handler: (input: unknown, context: unknown) => Promise<unknown>) {
      registered = { name, options, handler };
    } };
    registerMastraTool(server as never, tool, identity);
    expect(registered?.name).toBe(tool.id);
    expect(tool.strict).toBe(true);
    expect(registered?.options.inputSchema).toBe(tool.mcpInputSchema);
    expect(tool.mcpInputSchema.safeParse({ workspace_id: encodeId("workspace", workspaceId) }).success).toBe(true);
    const result = await registered!.handler({ workspace_id: encodeId("workspace", workspaceId) }, { mcpReq: { signal } });
    expect(result).toEqual({ content: [{ type: "text", text: JSON.stringify({ items: [], nextCursor: null }) }] });
    expect(listMeetings).toHaveBeenCalledWith(identity, workspaceId, undefined, signal, undefined, undefined);
  });

  it("retains the existing MCP names, descriptions, TypeIDs, defaults and errors", async () => {
    const listTranscript = vi.fn().mockResolvedValue({ items: [], nextCursor: null, next_after: null });
    const tools = createMeetingTools({
      getMeeting: vi.fn().mockResolvedValue(null),
      listTranscript,
    } as unknown as MeetingSyncService);
    expect(Object.keys(tools)).toEqual(["query_meetings", "get_meeting", "get_meeting_transcript"]);
    expect(tools.query_meetings.description).toBe("List meetings in a synchronized Workspace you can read.");
    expect(tools.get_meeting.description).toBe("Get one synchronized meeting you can read and its summary.");
    expect(tools.get_meeting_transcript.description).toContain("transcript_changed_refetch_without_after");
    await expect(tools.get_meeting_transcript.execute!({
      workspace_id: workspaceId, meeting_id: encodeId("meeting", workspaceId),
    } as never, { requestContext: meetingRequestContext(identity) } as never)).resolves.toMatchObject({ error: true });
    let transcriptHandler: ((input: unknown, context: unknown) => Promise<unknown>) | undefined;
    registerMastraTool({ registerTool(_name: string, _options: unknown, registered: typeof transcriptHandler) {
      transcriptHandler = registered;
    } } as never, tools.get_meeting_transcript, identity);
    await transcriptHandler!({
      workspace_id: encodeId("workspace", workspaceId), meeting_id: encodeId("meeting", workspaceId),
    }, { mcpReq: { signal: new AbortController().signal } });
    expect(listTranscript).toHaveBeenCalledWith(identity, workspaceId, workspaceId, undefined,
      expect.objectContaining({ wait: false }));
    let handler: ((input: unknown, context: unknown) => Promise<unknown>) | undefined;
    registerMastraTool({ registerTool(_name: string, _options: unknown, registered: typeof handler) { handler = registered; } } as never, tools.get_meeting, identity);
    await expect(handler!({ workspace_id: encodeId("workspace", workspaceId), meeting_id: encodeId("meeting", workspaceId) }, {
      mcpReq: { signal: new AbortController().signal },
    })).resolves.toEqual({ isError: true, content: [{ type: "text", text: "meeting_not_found" }] });
  });
});

describe("AI chat boundary", () => {
  it("accepts alternating page history ending in a user message", () => {
    expect(aiChatSchema.safeParse({ workspaceId, model: "model", reasoningEffort: "high", messages: [
      { role: "user", content: "Question" }, { role: "assistant", content: "Answer" }, { role: "user", content: "Follow-up" },
    ] }).success).toBe(true);
    expect(aiChatSchema.safeParse({ workspaceId: "workspace", model: "model", reasoningEffort: "high", messages: [
      { role: "user", content: "Question" }, { role: "user", content: "Second question" },
    ] }).success).toBe(false);
    expect(aiChatSchema.safeParse({ workspaceId: "workspace", model: "model", reasoningEffort: "high", messages: [
      { role: "user", content: "x".repeat(16_001) },
    ] }).success).toBe(false);
  });

  it("uses the configured OpenAI Responses endpoint and credentials", async () => {
    const logged = vi.spyOn(console, "error").mockImplementation(() => {});
    const transport = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) => {
      void _input; void _init;
      throw new Error("captured");
    });
    vi.stubGlobal("fetch", transport);
    const config = {
      provider: { backend: "openai", baseUrl: "https://provider.example/v1", apiKey: "secret" },
      baseUrl: "https://dahlia.example", foundationModels: ["gpt-5.6-test"],
    } as AppConfig;
    const gateway = { models: async () => ({
      data: [{ id: "gpt-5.6-test", display_name: "GPT Test" }],
      models: [{ slug: "gpt-5.6-test", display_name: "GPT Test", supported_in_api: true, visibility: "list",
        default_reasoning_level: "medium", supported_reasoning_levels: [{ effort: "low", description: "Fast" }, { effort: "medium", description: "Balanced" }] }],
    }) } as unknown as GatewayService;
    const service = createAiService(config, gateway, {} as never);
    const stream = service.stream({ workspaceId, model: "gpt-5.6-test", reasoningEffort: "low", messages: [{ role: "user", content: "Hello" }] }, identity,
      new Request("https://dahlia.example/api/v1/chat/messages"));
    await expect(stream[Symbol.asyncIterator]().next()).rejects.toThrow();
    expect(transport).toHaveBeenCalledOnce();
    const [input, init] = transport.mock.calls[0]!;
    expect(String(input)).toBe("https://provider.example/v1/responses");
    expect(new Headers(init?.headers).get("authorization")).toBe("Bearer secret");
    const body = JSON.parse(String(init?.body)) as {
      model?: string;
      reasoning?: { effort?: string };
      input?: Array<{ role?: string; content?: unknown }>;
    };
    expect(body).toMatchObject({ model: "gpt-5.6-test", reasoning: { effort: "low" } });
    const instructions = String(body.input?.find(({ role }) => role === "developer")?.content);
    expect(instructions).toContain(`context: ${JSON.stringify({ workspaceId: encodeId("workspace", workspaceId) })}`);
    expect(instructions).toContain("Pass context.workspaceId as workspace_id");
    expect(instructions).toContain("Set project_id to null unless the user asks to filter by Project");
    expect(instructions).toContain("Set cursor to null on the first query_meetings call");
    expect(logged).not.toHaveBeenCalled();
    logged.mockRestore();
    vi.unstubAllGlobals();
  });

  it("executes a model-requested meeting tool with the fixed Workspace context", async () => {
    const listMeetings = vi.fn().mockResolvedValue({ items: [] });
    const bodies: Array<{ store?: boolean; include?: string[]; input?: unknown; tools?: Array<{
      name?: string; strict?: boolean; parameters?: { required?: string[]; properties?: Record<string, unknown> };
    }> }> = [];
    let requestCount = 0;
    vi.stubGlobal("fetch", vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      bodies.push(JSON.parse(String(init?.body)) as { store?: boolean; include?: string[]; input?: unknown });
      requestCount += 1;
      if (requestCount === 1) return responsesStream(
        { type: "response.output_item.added", output_index: 0, item: { type: "reasoning", id: "reasoning-1", encrypted_content: "encrypted-reasoning" } },
        { type: "response.output_item.done", output_index: 0, item: { type: "reasoning", id: "reasoning-1", encrypted_content: "encrypted-reasoning" } },
        { type: "response.output_item.added", output_index: 0, item: { type: "function_call", id: "item-1", call_id: "call-1", name: "query_meetings", arguments: "", namespace: null } },
        { type: "response.function_call_arguments.delta", item_id: "item-1", output_index: 0, delta: JSON.stringify({ workspace_id: encodeId("workspace", workspaceId), query: null, project_id: null, cursor: null }) },
        { type: "response.output_item.done", output_index: 0, item: { type: "function_call", id: "item-1", call_id: "call-1", name: "query_meetings", arguments: JSON.stringify({ workspace_id: encodeId("workspace", workspaceId), query: null, project_id: null, cursor: null }), status: "completed", namespace: null } },
        { type: "response.completed", response: { incomplete_details: null, usage: { input_tokens: 1, output_tokens: 1 }, reasoning: null, service_tier: null } },
      );
      return responsesStream(
        { type: "response.output_item.added", output_index: 0, item: { type: "message", id: "message-1", phase: "final_answer" } },
        { type: "response.output_text.delta", item_id: "message-1", delta: "No meetings" },
        { type: "response.output_item.done", output_index: 0, item: { type: "message", id: "message-1", phase: "final_answer" } },
        { type: "response.completed", response: { incomplete_details: null, usage: { input_tokens: 1, output_tokens: 1 }, reasoning: null, service_tier: null } },
      );
    }));
    const config = {
      provider: { backend: "openai", baseUrl: "https://provider.example/v1", apiKey: "secret" },
      baseUrl: "https://dahlia.example", foundationModels: ["gpt-5.6-test"],
    } as AppConfig;
    const gateway = { models: async () => ({
      data: [{ id: "gpt-5.6-test", display_name: "GPT Test" }],
      models: [{ slug: "gpt-5.6-test", display_name: "GPT Test", supported_in_api: true, visibility: "list",
        default_reasoning_level: "medium", supported_reasoning_levels: [{ effort: "medium", description: "Balanced" }] }],
    }) } as unknown as GatewayService;
    const service = createAiService(config, gateway, createMeetingTools({ listMeetings } as unknown as MeetingSyncService));
    const request = new Request("https://dahlia.example/api/v1/chat/messages");
    const events = [];
    for await (const event of service.stream({ workspaceId, model: "gpt-5.6-test", reasoningEffort: "medium", messages: [{ role: "user", content: "List meetings" }] }, identity,
      request)) events.push(event);
    expect(events).toEqual([
      { type: "tool", name: "query_meetings", status: "running" },
      { type: "tool", name: "query_meetings", status: "complete" },
      { type: "text", text: "No meetings" },
    ]);
    expect(listMeetings).toHaveBeenCalledWith(identity, workspaceId, undefined, request.signal, undefined, undefined);
    expect(bodies).toHaveLength(2);
    expect(bodies[0]).toMatchObject({ store: false, include: ["reasoning.encrypted_content"] });
    const queryTool = bodies[0]?.tools?.find(({ name }) => name === "query_meetings");
    expect(queryTool?.parameters?.required).toEqual(["workspace_id", "query", "project_id", "cursor"]);
    expect(JSON.stringify(queryTool?.parameters?.properties)).toContain('"type":"null"');
    for (const tool of bodies[0]?.tools ?? []) {
      expect(tool.strict).toBe(true);
      expect(new Set(tool.parameters?.required)).toEqual(new Set(Object.keys(tool.parameters?.properties ?? {})));
    }
    expect(JSON.stringify(bodies[1]?.input)).toContain("encrypted-reasoning");
    vi.unstubAllGlobals();
  });

  it("uses the Databricks App service principal when the forwarded token is absent", async () => {
    const inference = vi.fn<(input: RequestInfo | URL, init?: RequestInit) => Promise<Response>>(
      async () => { throw new Error("captured"); },
    );
    const tokenTransport = vi.fn<typeof fetch>(async () => Response.json({
      access_token: "app-token", expires_in: 3600,
    }));
    vi.stubGlobal("fetch", inference);
    const config = {
      provider: { backend: "databricks", baseUrl: "https://workspace.example/ai-gateway/mlflow/v1" },
      databricksWorkspace: {
        host: "https://workspace.example", clientId: "app-client", clientSecret: "app-secret",
        tokenUrl: "https://workspace.example/oidc/v1/token",
      },
      baseUrl: "https://dahlia.example", foundationModels: ["system.ai.gpt-5-6-luna"],
    } as AppConfig;
    const gateway = { models: async () => ({
      data: [{ id: "system.ai.gpt-5-6-luna", display_name: "GPT 5.6 Luna" }],
      models: [{ slug: "system.ai.gpt-5-6-luna", display_name: "GPT 5.6 Luna", supported_in_api: true, visibility: "list",
        default_reasoning_level: "medium", supported_reasoning_levels: [{ effort: "medium", description: "Balanced" }] }],
    }) } as unknown as GatewayService;
    const service = createAiService(config, gateway, {} as never, tokenTransport);
    const stream = service.stream({
      workspaceId, model: "system.ai.gpt-5-6-luna", reasoningEffort: "medium", messages: [{ role: "user", content: "Hello" }],
    }, identity, new Request("https://dahlia.example/api/v1/chat/messages"));
    await expect(stream[Symbol.asyncIterator]().next()).rejects.toThrow("captured");
    expect(tokenTransport).toHaveBeenCalledOnce();
    expect(String(tokenTransport.mock.calls[0]![0])).toBe("https://workspace.example/oidc/v1/token");
    expect(String(inference.mock.calls[0]![0])).toBe("https://workspace.example/ai-gateway/mlflow/v1/responses");
    expect(new Headers(inference.mock.calls[0]![1]?.headers).get("authorization")).toBe("Bearer app-token");
    vi.unstubAllGlobals();
  });

  it("rejects models that are configured but not publicly Agent-compatible", async () => {
    const config = { provider: { backend: "openai", baseUrl: "https://provider.example/v1", apiKey: "secret" },
      baseUrl: "https://dahlia.example", foundationModels: ["hidden"] } as AppConfig;
    const gateway = { models: async () => ({ data: [{ id: "hidden", display_name: "Hidden" }],
      models: [{ slug: "hidden", supported_in_api: true, visibility: "hide", default_reasoning_level: "medium",
        supported_reasoning_levels: [{ effort: "medium", description: "Balanced" }] }] }) } as unknown as GatewayService;
    const service = createAiService(config, gateway, {} as never);
    const stream = service.stream({ workspaceId, model: "hidden", reasoningEffort: "medium", messages: [{ role: "user", content: "Hello" }] }, identity,
      new Request("https://dahlia.example/api/v1/chat/messages"));
    await expect(stream[Symbol.asyncIterator]().next()).rejects.toMatchObject({ status: 400, code: "model_not_configured" });
  });

  it("rejects a reasoning effort unsupported by the selected model", async () => {
    const config = { provider: { backend: "openai", baseUrl: "https://provider.example/v1", apiKey: "secret" },
      baseUrl: "https://dahlia.example", foundationModels: ["gpt-test"] } as AppConfig;
    const gateway = { models: async () => ({ data: [{ id: "gpt-test", display_name: "GPT Test" }],
      models: [{ slug: "gpt-test", supported_in_api: true, visibility: "list", default_reasoning_level: "low",
        supported_reasoning_levels: [{ effort: "low", description: "Fast" }] }] }) } as unknown as GatewayService;
    const service = createAiService(config, gateway, {} as never);
    const stream = service.stream({ workspaceId, model: "gpt-test", reasoningEffort: "high", messages: [{ role: "user", content: "Hello" }] }, identity,
      new Request("https://dahlia.example/api/v1/chat/messages"));
    await expect(stream[Symbol.asyncIterator]().next()).rejects.toMatchObject({ status: 400, code: "reasoning_effort_not_supported" });
  });

  it("parses text, sanitized tool state, error and done SSE events in order", async () => {
    const response = new Response([
      "event: text\ndata: {\"text\":\"Hello\"}\n\n",
      "event: tool\ndata: {\"name\":\"query_meetings\",\"status\":\"running\"}\n\n",
      "event: error\ndata: {\"code\":\"failed\"}\n\n",
      "event: done\ndata: {}\n\n",
    ].join(""), { headers: { "content-type": "text/event-stream" } });
    const events = [];
    for await (const event of readAiEvents(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "Hello" },
      { type: "tool", name: "query_meetings", status: "running" },
      { type: "error", code: "failed" },
      { type: "done" },
    ]);
    expect(JSON.stringify(events)).not.toContain("workspace_id");
  });

  it("does not duplicate messages when older pages overlap", () => {
    const current = [
      { id: "message-2", role: "user" as const, content: "Already visible" },
      { role: "assistant" as const, content: "New response" },
    ];
    expect(prependEarlierMessages(current, [
      { id: "message-1", role: "assistant", content: "Earlier" },
      { id: "message-2", role: "user", content: "Already visible" },
    ])).toEqual([
      { id: "message-1", role: "assistant", content: "Earlier" },
      ...current,
    ]);
  });

  it("restores only an AI prompt that was not persisted", () => {
    const attempted = { role: "user" as const, content: "Keep this question" };
    expect(recoverFailedDraft([], attempted, [])).toBe(attempted.content);
    expect(recoverFailedDraft([attempted], attempted, [])).toBe("");
    expect(recoverFailedDraft([attempted, { role: "assistant", content: "Saved answer" }], attempted, [])).toBe("");
    const previous = { id: "previous", role: "assistant" as const, content: "Previous answer" };
    const repeated = { role: "user" as const, content: "Repeated question" };
    const earlier = { role: "user" as const, content: repeated.content };
    expect(recoverFailedDraft([
      earlier, previous,
    ], repeated, [earlier, previous])).toBe(repeated.content);
    expect(recoverFailedDraft([
      earlier, previous, repeated,
    ], repeated, [earlier, previous])).toBe("");
    const idlessPrevious = { role: "assistant" as const, content: previous.content };
    expect(recoverFailedDraft([earlier, idlessPrevious], repeated, [earlier, idlessPrevious])).toBe(repeated.content);
    expect(recoverFailedDraft([
      earlier, idlessPrevious, repeated, { role: "assistant", content: "Partial answer" },
    ], repeated, [earlier, idlessPrevious])).toBe("");
  });

  it("keeps already loaded earlier pages when recovering the latest page", () => {
    const current = Array.from({ length: 60 }, (_, index) => ({
      id: `message-${index}`, role: index % 2 ? "assistant" as const : "user" as const, content: String(index),
    }));
    const stored = current.slice(10).map((message) => ({ ...message }));
    expect(mergeRecoveredMessages([...current, { role: "user", content: "Failed" }], stored)).toEqual(current);
  });
});

import { describe, expect, it } from "vitest";
import { toolStepLabel } from "../src/screens/AiChat";

describe("AI chat tool labels", () => {
  it("describes each Server agent tool by its effect", () => {
    const labels = Object.fromEntries([
      "query_meetings", "get_meeting", "get_meeting_transcript", "web_search", "web_fetch",
      "ask_user", "write_plan", "read_plan", "submit_plan",
      "save_memory", "delete_memory", "update_working_memory",
      "get_working_memory", "get_memory", "list_memories", "list_memory_scopes", "recall_memory", "reflect_memory",
      "recall_workspace_memory", "reflect_workspace_memory", "list_knowledge_pages", "get_knowledge_page", "recall",
      "task_update",
    ].map((name) => [name, toolStepLabel(name)]));
    expect(labels).toEqual({
      query_meetings: "Search meetings", get_meeting: "Read meeting", get_meeting_transcript: "Read transcript",
      web_search: "Search the web", web_fetch: "Read web page",
      ask_user: "Prepare question", write_plan: "Update plan", read_plan: "Read plan", submit_plan: "Submit plan",
      save_memory: "Update memory", delete_memory: "Update memory", update_working_memory: "Update memory",
      get_working_memory: "Read memory", get_memory: "Read memory", list_memories: "Read memory", list_memory_scopes: "Read memory",
      recall_memory: "Read memory", reflect_memory: "Read memory", recall_workspace_memory: "Read memory",
      reflect_workspace_memory: "Read memory", list_knowledge_pages: "Read memory", get_knowledge_page: "Read memory", recall: "Read memory",
      task_update: "Run task_update",
    });
  });
});

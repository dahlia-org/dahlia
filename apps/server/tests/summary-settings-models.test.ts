import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, it, vi } from "vitest";
import { ServerSummaryGeneration, ServerSummarySettings } from "../src/client/SummaryGeneration";
import { useLiveJSON } from "../src/client/live-data";
import { modelList } from "../src/ai-gateway/models";

vi.mock("../src/client/live-data", () => ({ useLiveJSON: vi.fn(), refreshData: vi.fn() }));
vi.mock("../src/client/api", () => ({ json: vi.fn(), uiText: (en: string) => en }));

it.each([{}, { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"] } }])(
  "hides summary settings and generation for unsupported capabilities: %j", (capabilities) => {
    vi.mocked(useLiveJSON).mockImplementation((url) => ({
      data: url === "/api/v1/capabilities" ? capabilities : undefined,
      loading: false, error: undefined, reload: vi.fn(),
    }));
    expect(renderToStaticMarkup(createElement(ServerSummarySettings))).toBe("");
    expect(renderToStaticMarkup(createElement(ServerSummaryGeneration, { base: "/test" }))).toBe("");
  },
);

it.each([false, true])("hides the automatic review alias from summary model choices (alias only: %s)", (aliasOnly) => {
  const catalog = modelList([
    { id: "codex-auto-review" },
    ...aliasOnly ? [] : [{ id: "gpt-5.6-terra" }],
  ]);
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? catalog
      : url === "/api/v1/capabilities" ? { meetingSummaryGeneration: { version: 1, sources: ["transcript"] } }
      : { settings: null },
    loading: false, error: undefined, reload: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummarySettings));
  expect(catalog.data.some(({ id }) => id === "codex-auto-review")).toBe(true);
  expect(html).not.toContain('value="codex-auto-review"');
  if (aliasOnly) expect(html).toContain("No models available");
  else expect(html).toContain('value="gpt-5.6-terra"');
});

it.each([true, false])("filters audio choices to available audio-capable Gemini (available: %s)", (available) => {
  const catalog = modelList([{ id: "gpt-5.6-terra" }, { id: "gemini-unknown" }, { id: "codex-auto-review" },
    ...(available ? [{ id: "gemini-3-8-flash" }, { id: "gemini-3-7-flash" }] : [])]);
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? catalog
      : url === "/api/v1/capabilities" ? { meetingSummaryGeneration: { version: 1, sources: ["transcript", "audio"] } }
      : { settings: { summary: { method: "audio", methodSettings: { audio: { model: "gemini-3-8-flash", reasoningEffort: "medium", detail: "standard" } } } } },
    loading: false, error: undefined, reload: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummarySettings));
  expect(html).toContain("Summary source"); expect(html).toContain("Audio and images");
  expect(html).not.toContain('value="gpt-5.6-terra"'); expect(html).not.toContain('value="codex-auto-review"');
  expect(html).not.toContain('value="gemini-unknown"');
  if (available) { expect(html).toContain('value="gemini-3-8-flash" selected'); expect(html).toContain('value="gemini-3-7-flash"'); }
  else expect(html).toContain("No models available");
});


it.each([
  ["summary_audio_empty", "No committed audio is available. Finish uploading recordings first."],
  ["summary_input_changed", "Inputs changed during generation. Retry after processing and uploads finish."],
  ["summary_http_400", "Summary failed; the existing summary was preserved."],
])("shows the existing failure message for %s", (error, message) => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/capabilities" ? { meetingSummaryGeneration: { version: 1, sources: ["audio"] } }
      : { job: { id: "test", status: "failed", error } },
    loading: false, error: undefined, reload: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummaryGeneration, { base: "/test" }));
  expect(html).toContain(message);
  expect(html).toContain(`(${error})`);
});

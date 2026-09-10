import { createElement, type ComponentProps } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, it, vi } from "vitest";
import { ServerSummaryGeneration, ServerSummarySettings } from "../src/client/SummaryGeneration";
import { useLiveJSON } from "../src/client/live-data";
import { DEFAULT_ACCOUNT_SETTINGS } from "../src/account-settings-model";
import { modelList } from "../src/ai-gateway/models";
import { isAudioSummaryModel, isStructuredSummaryModel, isSummaryModel } from "../src/summary/audio-model";

it("treats listed models as structured-output capable and rejects unregistered models", () => {
  const supported = ["gemini-3-8-flash", "gpt-6-astra", "gpt-5-6-sol", "gpt-5-6-terra", "gpt-5-6-luna", "gpt-5-5"];
  const unsupported = ["gpt-5.4-mini", "gpt-5.2", "gpt-5.4-pro", "gpt-unknown"];
  const catalog = modelList([...supported, ...unsupported].map((id) => ({ id })));
  for (const id of supported) expect(isStructuredSummaryModel(id, catalog)).toBe(true);
  for (const id of unsupported) expect(isStructuredSummaryModel(id, catalog)).toBe(false);
  expect(isStructuredSummaryModel("gpt-5.4", modelList([]))).toBe(false);
});

it.each([false, undefined])("does not require the legacy schema flag for a listed audio model (%s)", (support) => {
  const catalog = modelList([{ id: "gemini-3-8-flash" }]);
  const model = catalog.models.find(({ slug }) => slug === "gemini-3-8-flash")!;
  model.supports_json_schema = support;
  expect(isAudioSummaryModel(model.slug, catalog)).toBe(true);
  expect(isSummaryModel(model.slug, catalog, "audio")).toBe(true);
});

// These tests inspect available choices; real picker interactions run in tests/browser/select.html.
vi.mock("../src/client/Select", () => ({ Select: ({ value, disabled, children }: ComponentProps<typeof import("../src/client/Select").Select>) =>
  createElement("select", { value, disabled, onChange: () => {} }, children) }));
vi.mock("../src/client/live-data", async (original) => ({ ...await original<typeof import("../src/client/live-data")>(), useLiveJSON: vi.fn(), refreshData: vi.fn() }));
vi.mock("../src/client/api", async (original) => ({ ...await original<typeof import("../src/client/api")>(), json: vi.fn(), uiText: (en: string) => en }));

it.each([{}, { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"] } }])(
  "keeps common settings and hides generation for unsupported capabilities: %j", (capabilities) => {
    vi.mocked(useLiveJSON).mockImplementation((url) => ({
      data: typeof url === "object" && url.key.startsWith('["getCapabilities"') ? capabilities
        : typeof url === "object" && url.key.startsWith('["getSettings"') ? { settings: null } : undefined,
      loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
    }));
    const settings = renderToStaticMarkup(createElement(ServerSummarySettings));
    expect(settings).toContain("Output language");
    expect(settings).not.toContain("Summary source");
    const generation = renderToStaticMarkup(createElement(ServerSummaryGeneration, { meetingId: "test" }));
    if ("meetingSummaryGeneration" in capabilities) expect(generation).toContain("This account processes summaries in Dahlia for Mac.");
    else expect(generation).toBe("");
  },
);

it.each([false, true])("does not present made-up defaults while settings are unavailable (error: %s)", (failed) => {
  vi.mocked(useLiveJSON).mockReturnValue({
    data: undefined, loading: !failed, error: failed ? new Error("offline") : undefined,
    reload: vi.fn(), replace: vi.fn(),
  });
  const html = renderToStaticMarkup(createElement(ServerSummarySettings));
  expect(html).not.toContain("<select");
  expect(html).toContain(failed ? "Your saved preferences have not changed" : "Loading settings");
  if (failed) expect(html).toContain("Retry");
});

it("explains the selected style and the data sent by Mac processing", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: typeof url === "object" && url.key.startsWith('["getSettings"') ? { settings: DEFAULT_ACCOUNT_SETTINGS } : undefined,
    loading: false, error: undefined,
    reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummarySettings));
  expect(html).toContain("Topics, background, reasoning, open questions, and next steps.");
  expect(html).toContain("sends transcripts and images to the AI provider configured on that Mac");
  expect(html).not.toContain("Advanced server settings");
});

it("enables generation for the current remote settings shape", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["audio"] } }
      : typeof url === "object" && url.key.startsWith('["getSettings"')
        ? { settings: { ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote" } } }
        : { job: null },
    loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummaryGeneration, { meetingId: "test" }));
  expect(html).toContain('<button class="primary">Generate summary</button>');
  expect(html).not.toContain("This account processes summaries in Dahlia for Mac.");
});

it("does not offer remote processing when the server only supports transcript input", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["transcript"] } }
      : typeof url === "object" && url.key.startsWith('["getSettings"')
        ? { settings: { ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote" } } }
        : undefined,
    loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const settings = renderToStaticMarkup(createElement(ServerSummarySettings));
  expect(settings).toContain('value="remote" disabled="" selected=""');
  expect(settings).toContain("Remote processing is unavailable on this server.");
  const generation = renderToStaticMarkup(createElement(ServerSummaryGeneration, { meetingId: "test" }));
  expect(generation).toContain("Remote summary generation is unavailable on this server.");
  expect(generation).toContain('button class="primary" disabled=""');
});

it.each([false, true])("hides the automatic review alias from summary model choices (alias only: %s)", (aliasOnly) => {
  const catalog = modelList([
    { id: "codex-auto-review" },
    ...aliasOnly ? [] : [{ id: "gemini-3-8-flash" }],
  ]);
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? catalog
      : typeof url === "object" && url.key.startsWith('["getCapabilities"') ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"] } }
      : { settings: { ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote" } } },
    loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummarySettings));
  expect(catalog.data.some(({ id }) => id === "codex-auto-review")).toBe(true);
  expect(html).not.toContain('value="codex-auto-review"');
  if (aliasOnly) expect(html).toContain("No models available");
  else expect(html).toContain('value="gemini-3-8-flash"');
});

it.each([true, false])("filters audio choices to available audio-capable Gemini (available: %s)", (available) => {
  const catalog = modelList([{ id: "gpt-5-6-terra" }, { id: "gemini-unknown" }, { id: "codex-auto-review" },
    ...(available ? [{ id: "gemini-3-8-flash" }, { id: "gemini-3-7-flash" }] : [])]);
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? catalog
      : typeof url === "object" && url.key.startsWith('["getCapabilities"') ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"] } }
      : { settings: { ...DEFAULT_ACCOUNT_SETTINGS, summary: { style: "standard" }, processing: { location: "remote", remote: {
        workflow: "combined", summaryModel: "gemini-3-8-flash", reasoningEffort: "medium",
      } } } },
    loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummarySettings));
  expect(html).toContain("Processing location");
  expect(html).not.toContain('value="gpt-5-6-terra"'); expect(html).not.toContain('value="codex-auto-review"');
  expect(html).not.toContain('value="gemini-unknown"');
  if (available) { expect(html).toContain('value="gemini-3-8-flash" selected'); expect(html).toContain('value="gemini-3-7-flash"'); }
  else {
    expect(html).toContain("No models available");
    expect(html).toContain("A selected model is unavailable. Open advanced settings");
  }
});


it.each([
  ["summary_audio_empty", "No committed audio is available. Finish uploading recordings first."],
  ["summary_input_changed", "Inputs changed during generation. Retry after processing and uploads finish."],
  ["summary_http_400", "Summary failed; the existing summary was preserved."],
])("shows the existing failure message for %s", (error, message) => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: typeof url === "object" && url.key.startsWith('["getCapabilities"') ? { meetingSummaryGeneration: { version: 2, sources: ["audio"] } }
      : typeof url === "object" && url.key.startsWith('["getSettings"') ? { settings: { ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote" } } }
      : { job: { id: "test", status: "failed", error } },
    loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummaryGeneration, { meetingId: "test" }));
  expect(html).toContain(message);
  expect(html).toContain(`(${error})`);
});

it("keeps the shared output language editable without summary capability", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: typeof url === "object" && url.key.startsWith('["getSettings"') ? { settings: { ...DEFAULT_ACCOUNT_SETTINGS, outputLanguage: "fr" } } : url ? {} : undefined,
    loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummarySettings));
  expect(html).toContain('value="fr" selected');
  expect(html).toContain("Shared by summaries and image analysis");
  expect(html).not.toContain("Summary source");
});

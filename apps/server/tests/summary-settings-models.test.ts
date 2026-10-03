import { createElement, type ComponentProps } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, it, vi } from "vitest";
import { loadTranscript, SummaryGenerationSurface, ServerSummarySettings } from "../src/client/SummaryGeneration";
import { useLiveJSON } from "../src/client/live-data";
import { apiOperations as api } from "../src/client/generated-operations";
import { DEFAULT_WORKSPACE_GENERATION_SETTINGS } from "../src/workspace-generation-settings";
import { modelList } from "../src/ai-gateway/models";
import { cloudflareModels } from "../src/ai-gateway/cloudflare";
import { isAudioSummaryModel, isStructuredSummaryModel, isSummaryModel } from "../src/summary/audio-model";

function generationButton(html: string): string {
  return html.match(/<button[^>]*>Generate summary<\/button>/)?.[0] ?? "";
}

function generationDisabled(html: string): boolean {
  return /\sdisabled(?:=""|(?=>))/.test(generationButton(html));
}

function sourceInput(html: string, source: "audio" | "transcript"): string {
  return html.match(new RegExp(`<input[^>]*name="summary-source-test"[^>]*value="${source}"[^>]*>`))?.[0] ?? "";
}

it("treats listed models as structured-output capable and rejects unregistered models", () => {
  const supported = ["system.ai.gemini-3-8-flash", "system.ai.gpt-6-astra", "system.ai.gpt-5-6-sol", "system.ai.gpt-5-6-terra", "system.ai.gpt-5-6-luna", "system.ai.gpt-5-5"];
  const unsupported = ["gpt-5.4-mini", "gpt-5.2", "gpt-5.4-pro", "gpt-unknown"];
  const catalog = modelList([...supported, ...unsupported].map((id) => ({ id })));
  for (const id of supported) expect(isStructuredSummaryModel(id, catalog)).toBe(true);
  for (const id of unsupported) expect(isStructuredSummaryModel(id, catalog)).toBe(false);
  expect(isStructuredSummaryModel("gpt-5.4", modelList([]))).toBe(false);
});

it.each([false, undefined])("does not require the legacy schema flag for a listed audio model (%s)", (support) => {
  const catalog = modelList([{ id: "system.ai.gemini-3-8-flash" }]);
  const model = catalog.models.find(({ slug }) => slug === "system.ai.gemini-3-8-flash")!;
  model.supports_json_schema = support;
  expect(isAudioSummaryModel(model.slug, catalog)).toBe(true);
  expect(isSummaryModel(model.slug, catalog, "audio")).toBe(true);
});

it.each([[true, true], [false, false]] as const)("checks semantic transcript availability from one manifest request (%s)", async (hasText, available) => {
  const first = vi.spyOn(api, "getLatestTranscript").mockResolvedValue({
    formatVersion: 1, version: 7, entityId: "meeting", present: true, count: 1, byteCount: 4,
    sha256: "test", entity: "transcript", syncRevision: 7, transcript: null, hasText, items: undefined, nextCursor: null,
  });
  const version = vi.spyOn(api, "getTranscript");
  try {
    await expect(loadTranscript("meeting")).resolves.toEqual({ version: 7, available });
    expect(first).toHaveBeenCalledOnce();
    expect(first).toHaveBeenCalledWith(expect.objectContaining({
      params: { path: { meetingId: "meeting" }, query: { manifest: "1" } },
    }));
    expect(version).not.toHaveBeenCalled();
  } finally {
    first.mockRestore(); version.mockRestore();
  }
});

// These tests inspect available choices; real picker interactions run in tests/browser/select.html.
vi.mock("../src/client/Select", () => ({ Select: ({ value, disabled, children }: ComponentProps<typeof import("../src/client/Select").Select>) =>
  createElement("select", { value, disabled, onChange: () => {} }, children) }));
vi.mock("../src/client/live-data", async (original) => ({ ...await original<typeof import("../src/client/live-data")>(), useLiveJSON: vi.fn(), refreshData: vi.fn() }));
vi.mock("../src/client/api", async (original) => ({ ...await original<typeof import("../src/client/api")>(), json: vi.fn(), uiText: (en: string) => en }));

const transcript = (available: boolean) => ({ version: 3, available });
const recordings = (complete: boolean) => ({
  items: complete ? [{ audio: { mic: { fileId: "mic" } } }] : [],
  recordings: complete ? [{ micFileId: "mic", systemFileId: null }] : [], complete,
});

it.each([{}, { meetingSummaryGeneration: { version: 1, sources: ["transcript", "audio"] } }])(
  "keeps common settings and shows disabled generation for unsupported capabilities: %j", (capabilities) => {
    vi.mocked(useLiveJSON).mockImplementation((url) => ({
      data: url === "/api/v1/models" ? modelList([]) : typeof url === "object" && url.key.startsWith('["getCapabilities"') ? capabilities
        : typeof url === "object" && url.key.startsWith('["getWorkspace"') ? { role: "admin", generationSettings: DEFAULT_WORKSPACE_GENERATION_SETTINGS } : undefined,
      loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
    }));
    const settings = renderToStaticMarkup(createElement(ServerSummarySettings, { workspaceId: "test", onSave: async () => {} }));
    expect(settings).toContain("Output language");
    expect(settings).not.toContain("Summary source");
    expect(settings).not.toContain("Summary model");
    expect(settings).not.toContain("Transcription location");
    const generation = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
    expect(generation).toContain("This server does not support this source.");
    expect(generationDisabled(generation)).toBe(true);
  },
);

it.each([false, true])("shows capability discovery loading/error separately from unsupported generation (error: %s)", (failed) => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: typeof url === "object" && url.key.startsWith('["getWorkspace"')
      ? { role: "admin", generationSettings: DEFAULT_WORKSPACE_GENERATION_SETTINGS } : undefined,
    loading: typeof url === "object" && url.key.startsWith('["getCapabilities"') && !failed,
    refreshing: false,
    error: typeof url === "object" && url.key.startsWith('["getCapabilities"') && failed ? new Error("capabilities offline") : undefined,
    reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummarySettings, { workspaceId: "test", onSave: async () => {} }));
  expect(html).toContain("Output language");
  expect(html).toContain("Server generation defaults");
  expect(html).toContain(failed ? "capabilities offline" : "Loading");
  if (failed) expect(html).toContain("Retry");
  expect(html).not.toContain("Summary model");
});

it.each([false, true])("does not present made-up defaults while settings are unavailable (error: %s)", (failed) => {
  vi.mocked(useLiveJSON).mockReturnValue({
    data: undefined, loading: !failed, refreshing: !failed, error: failed ? new Error("offline") : undefined,
    reload: vi.fn(), replace: vi.fn(),
  });
  const html = renderToStaticMarkup(createElement(ServerSummarySettings, { workspaceId: "test", onSave: async () => {} }));
  expect(html).not.toContain("<select");
  expect(html).toContain(failed ? "offline" : "Loading");
  if (failed) expect(html).toContain("Retry");
});

it("exposes only the shared language and explains device settings", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? modelList([]) : typeof url === "object" && url.key.startsWith('["getWorkspace"') ? { role: "admin", generationSettings: DEFAULT_WORKSPACE_GENERATION_SETTINGS } : undefined,
    loading: false, refreshing: false, error: undefined,
    reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummarySettings, { workspaceId: "test", onSave: async () => {} }));
  expect(html).toContain("Desktop transcription and summaries run on the Mac with account settings stored on that Mac.");
  expect(html).toContain("Web operations run on the server using the defaults below, with overrides available when starting them.");
  expect(html).toContain("Generated content language");
  expect(html).not.toContain("Transcription location");
  expect(html).not.toContain("Summary model");
  expect(html).not.toContain("After recording");
});

it("uses shared language and server style while ignoring Desktop routing and audio models for text", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? modelList([{ id: "system.ai.gpt-5-6-luna" }])
      : typeof url === "object" && url.key.startsWith('["getCapabilities"')
        ? { meetingSummaryGeneration: { version: 2, sources: ["transcript"], completeRecordings: true } }
        : typeof url === "object" && url.key.startsWith('["getWorkspace"')
          ? { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, outputLanguage: "fr", summary: { style: "standard" },
            processing: { location: "local", remote: { workflow: "combined", summaryModel: "system.ai.gpt-5-6-luna" } } } }
          : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(true)
          : { job: null },
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(html).toContain("Français (default)");
  expect(html).toContain("Automatic (default)");
  expect(html).toContain("Standard (default)");
  expect(html).not.toContain("Workspace default");
});

it.each([
  ["audio", undefined, true, false],
  ["audio", "system.ai.gemini-3-8-flash", true, false],
  ["audio", "system.ai.gpt-5-6-terra", false, false],
  ["transcript", "system.ai.gpt-5-6-terra", true, false],
  ["audio", "system.ai.gpt-5-6-terra", false, true],
] as const)("validates the saved server %s model %s (available: %s, empty catalog: %s)", (source, summaryModel, available, emptyCatalog) => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? modelList(emptyCatalog ? [] : [{ id: "system.ai.gemini-3-8-flash" }, { id: "system.ai.gpt-5-6-terra" }]) : typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: [source], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getWorkspace"')
        ? { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: {
          location: "remote", remote: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing.remote, summaryModel },
        } } }
        : typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"') ? recordings(true)
        : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(true)
        : { job: null },
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(generationDisabled(html)).toBe(!available);
  if (!available) {
    expect(html).toContain(`${summaryModel} (default) — Unavailable`);
    expect(generationDisabled(html)).toBe(true);
  }
  expect(html).not.toContain("This workspace processes summaries in Dahlia for Mac.");
});

it("does not apply a combined-audio model override to manual transcript generation", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? cloudflareModels()
      : typeof url === "object" && url.key.startsWith('["getCapabilities"')
        ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"], completeRecordings: true } }
        : typeof url === "object" && url.key.startsWith('["getWorkspace"')
          ? { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: {
            location: "remote", remote: { workflow: "combined", summaryModel: "gemini-3-flash", reasoningEffort: "high" },
          } } }
          : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(true)
          : typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"') ? recordings(true)
          : { job: null },
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(html).toContain('checked="" value="transcript"');
  expect(html).toContain('<select><option value="__default" selected="">Automatic (default)</option><option value="">Automatic</option><option value="gpt-4.1">GPT-4.1</option></select>');
  expect(generationDisabled(html)).toBe(false);
  expect(html).not.toContain('gemini-3-flash — Unavailable');
  expect(html).not.toContain('high — Check model compatibility');
});

it.each([
  ["loading", false], ["error", false], ["loading", true], ["error", true],
] as const)("keeps generation available while the model catalog is %s (cached: %s)", (state, cached) => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? (cached ? modelList([]) : undefined) : typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["transcript"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getWorkspace"')
        ? { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: {
          location: "remote", remote: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing.remote, transcriptSummaryModel: "system.ai.gpt-5-6-terra" },
        } } }
        : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(true)
        : { job: null },
    loading: state === "loading" && url === "/api/v1/models",
    refreshing: state === "loading" && url === "/api/v1/models",
    error: state === "error" && url === "/api/v1/models" ? new Error("offline") : undefined,
    reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(generationDisabled(html)).toBe(false);
  expect(html).toContain('<option value="__default" selected="">Automatic (default)</option>');
  expect(html).not.toContain("Unavailable");
  const settingsHTML = renderToStaticMarkup(createElement(ServerSummarySettings, { workspaceId: "test", onSave: async () => {} }));
  expect(settingsHTML).not.toContain("Unavailable");
  expect(settingsHTML).not.toContain("A selected model is unavailable");
  expect(settingsHTML).not.toContain("No models available");
});

it.each(["loading", "error"] as const)("does not use stale complete recordings while availability is %s", (state) => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? modelList([]) : typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["audio"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getWorkspace"')
        ? { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing, location: "remote" } } }
        : typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"') ? recordings(true)
        : { job: null },
    loading: state === "loading" && typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"'),
    refreshing: state === "loading" && typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"'),
    error: state === "error" && typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"')
      ? new Error("offline") : undefined,
    reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(sourceInput(html, "audio")).toContain("disabled");
  expect(generationDisabled(html)).toBe(true);
});

it("keeps automatic recording processing unavailable but allows manual transcript generation", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? modelList([]) : typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["transcript"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getWorkspace"')
        ? { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing, location: "remote" } } }
        : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(true)
        : undefined,
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const settings = renderToStaticMarkup(createElement(ServerSummarySettings, { workspaceId: "test", onSave: async () => {} }));
  expect(settings).not.toContain('value="remote"');
  expect(settings).not.toContain("After recording");
  const generation = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(generation).toContain('checked="" value="transcript"');
  expect(generationDisabled(generation)).toBe(false);
});

it("keeps audio disabled for servers that do not guarantee complete recordings", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? modelList([]) : typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"] } }
      : typeof url === "object" && url.key.startsWith('["getWorkspace"')
        ? { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing, location: "remote" } } }
        : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(true)
        : { job: null },
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));

  const html = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(html).toContain('checked="" value="transcript"');
  expect(sourceInput(html, "audio")).toContain("disabled");
});

it.each([
  [true, true, "transcript"],
  [false, true, "audio"],
  [true, false, "transcript"],
] as const)("prefers transcript and falls back to audio (transcript: %s, audio: %s)", (hasText, hasAudio, preferred) => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? modelList([]) : typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getWorkspace"')
        ? { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing, location: "remote" } } }
        : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(hasText)
        : typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"') ? recordings(hasAudio)
        : { job: null },
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(html).toContain(`checked="" value="${preferred}"`);
  if (!hasAudio) expect(html).toContain("No committed recording audio is available.");
});

it("disables generation when neither source is available", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? modelList([]) : typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getWorkspace"')
        ? { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing, location: "remote" } } }
        : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(false)
        : typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"') ? recordings(false)
        : { job: null },
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(generationDisabled(html)).toBe(true);
  expect(html).toContain("The latest transcript is empty or has not been saved.");
  expect(html).toContain("No committed recording audio is available.");
});

it.each([false, true])("hides the automatic review alias from summary model choices (alias only: %s)", (aliasOnly) => {
  const catalog = modelList([
    { id: "codex-auto-review" },
    ...aliasOnly ? [] : [{ id: "system.ai.gemini-3-8-flash" }],
  ]);
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? catalog
      : typeof url === "object" && url.key.startsWith('["getCapabilities"') ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"') ? recordings(true)
      : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(false)
      : { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing, location: "remote" } } },
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(catalog.data.some(({ id }) => id === "codex-auto-review")).toBe(true);
  expect(html).not.toContain('value="codex-auto-review"');
  if (aliasOnly) expect(html).toContain("Automatic (default)");
  else expect(html).toContain('value="system.ai.gemini-3-8-flash"');
});

it.each([true, false])("filters audio choices to available audio-capable Gemini (available: %s)", (available) => {
  const catalog = modelList([{ id: "system.ai.gpt-5-6-terra" }, { id: "system.ai.gemini-unknown" }, { id: "codex-auto-review" },
    ...(available ? [{ id: "system.ai.gemini-3-8-flash" }, { id: "system.ai.gemini-3-7-flash" }] : [])]);
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? catalog
      : typeof url === "object" && url.key.startsWith('["getCapabilities"') ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"') ? recordings(true)
      : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(false)
      : { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, summary: { style: "standard" }, processing: { location: "remote", remote: {
        workflow: "combined", summaryModel: "system.ai.gemini-3-8-flash", reasoningEffort: "medium",
      } } } },
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(html).toContain('checked="" value="audio"');
  expect(html).not.toContain('value="system.ai.gpt-5-6-terra"'); expect(html).not.toContain('value="codex-auto-review"');
  expect(html).not.toContain('value="system.ai.gemini-unknown"');
  if (available) { expect(html).toContain('value="system.ai.gemini-3-8-flash"'); expect(html).toContain('value="system.ai.gemini-3-7-flash"'); }
  else {
    expect(html).toContain("system.ai.gemini-3-8-flash (default) — Unavailable");
    expect(generationDisabled(html)).toBe(true);
  }
});

it("keeps explicit server workflow defaults without automatic processing controls", () => {
  const catalog = modelList([{ id: "system.ai.gemini-3-8-flash" }, { id: "system.ai.gpt-5-6-luna" }]);
  const render = (workflow: "combined" | "transcribeThenSummarize") => {
    vi.mocked(useLiveJSON).mockImplementation((url) => ({
      data: url === "/api/v1/models" ? catalog
        : typeof url === "object" && url.key.startsWith('["getCapabilities"')
          ? { meetingSummaryGeneration: { version: 2, sources: ["audio"], completeRecordings: true } }
          : { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS,
            processing: { location: "remote", remote: { workflow } } } },
      loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
    }));
    return renderToStaticMarkup(createElement(ServerSummarySettings, { workspaceId: "test", onSave: async () => {} }));
  };
  const combined = render("combined");
  const twoStage = render("transcribeThenSummarize");
  expect(combined).not.toBe(twoStage);
  expect(combined).toContain('value="combined" selected');
  expect(twoStage).toContain('value="transcribeThenSummarize" selected');
  expect(combined).toContain("Server generation defaults");
  expect(combined).toContain("Summary model");
  expect(combined).not.toContain("Audio processing model");
  expect(combined).not.toContain("Transcript summary model");
  expect(combined).toContain('value="system.ai.gemini-3-8-flash"');
  expect(combined).not.toContain('value="system.ai.gpt-5-6-luna"');
  expect(twoStage).toContain("Audio processing model");
  expect(twoStage).toContain("Transcript summary model");
  expect(twoStage).toContain("Summary style");
  expect(combined).toContain("receiving them does not start server generation");
  expect(combined).toContain("Output language");
  expect(combined).not.toContain("Summary method");
  expect(combined).not.toContain("After recording");
});


it.each([
  ["summary_audio_empty", "No committed audio is available. Finish uploading recordings first."],
  ["summary_input_changed", "Inputs changed during generation. Retry after processing and uploads finish."],
  ["summary_http_400", "Summary failed; the existing summary was preserved."],
])("shows the existing failure message for %s", (error, message) => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? modelList([]) : typeof url === "object" && url.key.startsWith('["getCapabilities"') ? { meetingSummaryGeneration: { version: 2, sources: ["audio"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getWorkspace"') ? { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing, location: "remote" } } }
      : { job: { id: "test", status: "failed", error } },
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(SummaryGenerationSurface, { meetingId: "test", workspaceId: "test" }));
  expect(html).toContain(message);
  expect(html).toContain(`(${error})`);
});

it("keeps the shared output language editable without summary capability", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? modelList([]) : typeof url === "object" && url.key.startsWith('["getWorkspace"') ? { role: "admin", generationSettings: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, outputLanguage: "fr" } } : url ? {} : undefined,
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummarySettings, { workspaceId: "test", onSave: async () => {} }));
  expect(html).toContain('value="fr" selected');
  expect(html).toContain("Shared by summaries and image descriptions");
  expect(html).not.toContain("Summary source");
});

it.each(["editor", "viewer"])("renders shared settings read-only for %s", (role) => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({ data: url === "/api/v1/models" ? modelList([]) : typeof url === "object" && url.key.startsWith('["getWorkspace"') ? { role, generationSettings: DEFAULT_WORKSPACE_GENERATION_SETTINGS } : undefined,
    loading: false, refreshing: false, error: undefined, reload: vi.fn(), replace: vi.fn() }));
  const html = renderToStaticMarkup(createElement(ServerSummarySettings, { workspaceId: "test", onSave: async () => {} }));
  expect(html).toMatch(/<fieldset[^>]*disabled=""/);
  expect(html).not.toContain("Only admins can change these defaults");
});

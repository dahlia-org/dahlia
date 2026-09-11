import { createElement, type ComponentProps } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, it, vi } from "vitest";
import { loadTranscript, ServerSummaryGeneration, ServerSummarySettings, shouldResetManualSummaryModel } from "../src/client/SummaryGeneration";
import { useLiveJSON } from "../src/client/live-data";
import { apiOperations as api } from "../src/client/generated-operations";
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

it("resets a saved model only when the catalog confirms it is incompatible with the manual source", () => {
  const catalog = modelList([{ id: "gpt-5-6-luna" }]);
  expect(shouldResetManualSummaryModel("missing", catalog, "transcript")).toBe(false);
  expect(shouldResetManualSummaryModel("gpt-5-6-luna", { ...catalog, models: [] }, "audio")).toBe(false);
  expect(shouldResetManualSummaryModel("gpt-5-6-luna", catalog, "transcript")).toBe(false);
  expect(shouldResetManualSummaryModel("gpt-5-6-luna", catalog, "audio")).toBe(true);
});

it("pins transcript pagination to the version returned by the first latest page", async () => {
  const first = vi.spyOn(api, "getLatestTranscript").mockResolvedValue({
    formatVersion: 1, version: 7, entityId: "meeting", present: true, count: 1, byteCount: 4,
    sha256: "test", entity: "transcript", syncRevision: 7, transcript: null, items: [], nextCursor: "cursor",
  });
  const version = vi.spyOn(api, "getTranscript").mockResolvedValue({
    formatVersion: 1, version: 7, entityId: "meeting", present: true, count: 1, byteCount: 4,
    sha256: "test", entity: "transcript", syncRevision: 7, transcript: null,
    items: [{ segmentId: "segment", startedAt: "2026-09-09T00:00:00Z", endedAt: null, text: "Text",
      createdAt: null, audioSource: null, speakerLabel: null }], nextCursor: null,
  });
  try {
    await expect(loadTranscript("meeting")).resolves.toEqual({ version: 7, available: true });
    expect(first).toHaveBeenCalledOnce();
    expect(version).toHaveBeenCalledWith(expect.objectContaining({
      params: { path: { meetingId: "meeting", version: "7" }, query: { cursor: "cursor" } },
    }));
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
    expect(generation).toBe("");
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
      ? { meetingSummaryGeneration: { version: 2, sources: ["audio"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getSettings"')
        ? { settings: { ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote" } } }
        : typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"') ? recordings(true)
        : { job: null },
    loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummaryGeneration, { meetingId: "test" }));
  expect(html).toContain('<button class="primary">Generate summary</button>');
  expect(html).not.toContain("This account processes summaries in Dahlia for Mac.");
});

it.each(["loading", "error"] as const)("does not use stale complete recordings while availability is %s", (state) => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["audio"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getSettings"')
        ? { settings: { ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote" } } }
        : typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"') ? recordings(true)
        : { job: null },
    loading: state === "loading" && typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"'),
    error: state === "error" && typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"')
      ? new Error("offline") : undefined,
    reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummaryGeneration, { meetingId: "test" }));
  expect(html).toContain('<input type="radio" disabled="" name="summary-source-test" value="audio"/>');
  expect(html).toContain('button class="primary" disabled=""');
});

it("keeps automatic recording processing unavailable but allows manual transcript generation", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["transcript"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getSettings"')
        ? { settings: { ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote" } } }
        : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(true)
        : undefined,
    loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const settings = renderToStaticMarkup(createElement(ServerSummarySettings));
  expect(settings).toContain('value="remote" disabled="" selected=""');
  expect(settings).toContain("Remote processing is unavailable on this server.");
  const generation = renderToStaticMarkup(createElement(ServerSummaryGeneration, { meetingId: "test" }));
  expect(generation).toContain('checked="" value="transcript"');
  expect(generation).toContain('<button class="primary">Generate summary</button>');
});

it("keeps audio disabled for servers that do not guarantee complete recordings", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"] } }
      : typeof url === "object" && url.key.startsWith('["getSettings"')
        ? { settings: { ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote" } } }
        : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(true)
        : { job: null },
    loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));

  const html = renderToStaticMarkup(createElement(ServerSummaryGeneration, { meetingId: "test" }));
  expect(html).toContain('checked="" value="transcript"');
  expect(html).toContain('<input type="radio" disabled="" name="summary-source-test" value="audio"/>');
});

it.each([
  [true, true, "transcript"],
  [false, true, "audio"],
  [true, false, "transcript"],
] as const)("prefers transcript and falls back to audio (transcript: %s, audio: %s)", (hasText, hasAudio, preferred) => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getSettings"')
        ? { settings: { ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote" } } }
        : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(hasText)
        : typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"') ? recordings(hasAudio)
        : { job: null },
    loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummaryGeneration, { meetingId: "test" }));
  expect(html).toContain(`checked="" value="${preferred}"`);
  if (!hasAudio) expect(html).toContain("No committed recording audio is available.");
});

it("disables generation when neither source is available", () => {
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: typeof url === "object" && url.key.startsWith('["getCapabilities"')
      ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"], completeRecordings: true } }
      : typeof url === "object" && url.key.startsWith('["getSettings"')
        ? { settings: { ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote" } } }
        : typeof url === "object" && url.key.startsWith('["summaryTranscriptAvailability"') ? transcript(false)
        : typeof url === "object" && url.key.startsWith('["summaryRecordingAvailability"') ? recordings(false)
        : { job: null },
    loading: false, error: undefined, reload: vi.fn(), replace: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummaryGeneration, { meetingId: "test" }));
  expect(html).toContain('button class="primary" disabled=""');
  expect(html).toContain("The latest transcript is empty or has not been saved.");
  expect(html).toContain("No committed recording audio is available.");
});

it.each([false, true])("hides the automatic review alias from summary model choices (alias only: %s)", (aliasOnly) => {
  const catalog = modelList([
    { id: "codex-auto-review" },
    ...aliasOnly ? [] : [{ id: "gemini-3-8-flash" }],
  ]);
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? catalog
      : typeof url === "object" && url.key.startsWith('["getCapabilities"') ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"], completeRecordings: true } }
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
      : typeof url === "object" && url.key.startsWith('["getCapabilities"') ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"], completeRecordings: true } }
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
    data: typeof url === "object" && url.key.startsWith('["getCapabilities"') ? { meetingSummaryGeneration: { version: 2, sources: ["audio"], completeRecordings: true } }
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

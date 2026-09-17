import { apiOperations as api } from "./generated-operations";
import type { components, operations } from "./generated-api";
import { apiQuery } from "./live-data";
import { Select } from "./Select";
import { MenuIcon } from "./Sidebar";
import { Tooltip } from "./Tooltip";
import { useEffect, useRef, useState } from "react";
import { RequestError, uiText } from "./api";
import { refreshData, useLiveJSON } from "./live-data";
import { encodeId } from "../typeid";
import { uuidV7 } from "../id";
import type { GatewayModelList } from "../ai-gateway/backend";
import { DEFAULT_WORKSPACE_GENERATION_SETTINGS, summaryStyles, summaryStyleDetail, type WorkspaceGenerationSettings } from "../workspace-generation-settings";
type SummaryRequest = operations["startSummaryJob"]["requestBody"]["content"]["application/json"];
import { isSummaryModel } from "../summary/audio-model";
import { CODEX_AUTO_REVIEW_ALIAS } from "../ai-gateway/model-alias";

type SummarySource = "transcript" | "audio";
type Recording = components["schemas"]["Recording"];
type TranscriptContent = components["schemas"]["TranscriptContent"];
type TranscriptSnapshot = { version: number; available: boolean };
type RecordingSnapshot = {
  items: Recording[];
  recordings: { micFileId: string | null; systemFileId: string | null }[];
  complete: boolean;
};

async function loadRecordings(meetingId: string, signal?: AbortSignal): Promise<RecordingSnapshot> {
  const items: Recording[] = [];
  let cursor: string | null = null;
  do {
    const page = await api.listRecordings({ signal, headers: { "X-Dahlia-Require-Complete-Recordings": "1" },
      params: { path: { meetingId }, query: { cursor: cursor ?? undefined } } });
    items.push(...page.items);
    cursor = page.nextCursor;
  } while (cursor !== null);
  return {
    items,
    recordings: items.map(({ audio }) => ({
      micFileId: audio.mic?.fileId ?? null,
      systemFileId: audio.system?.fileId ?? null,
    })),
    complete: items.length > 0 && items.every(({ audio }) => {
      const tracks = Object.values(audio);
      return tracks.length > 0 && tracks.every(({ fileId }) => !!fileId);
    }),
  };
}

export async function loadTranscript(meetingId: string, signal?: AbortSignal): Promise<TranscriptSnapshot> {
  let cursor: string | null = null;
  let version: number | undefined;
  while (true) {
    let page: TranscriptContent;
    if (version === undefined) {
      page = await api.getLatestTranscript({ signal, params: { path: { meetingId }, query: {} } });
    } else {
      page = await api.getTranscript({ signal, params: { path: { meetingId, version: String(version) }, query: { cursor: cursor ?? undefined } } });
    }
    version ??= page.version;
    if (page.version !== version) throw new Error("Transcript version changed while loading");
    if (page.items?.some(({ text }) => text.trim() !== "")) return { version, available: true };
    if (!page.nextCursor) return { version, available: false };
    cursor = page.nextCursor;
  }
}

const summaryErrors: Record<string, string> = {
  summary_audio_empty: uiText("No committed audio is available. Finish uploading recordings first.", "確定済みの音声がありません。録音のアップロード完了後に再試行してください。"),
  summary_audio_too_long: uiText("Combined mic/system audio exceeds 9.5 hours.", "マイク・システム音声の合計が9.5時間を超えています。"),
  summary_audio_request_too_large: uiText("The provider rejected the request size. No audio was truncated.", "モデルの送信サイズ上限を超えました。音声は切り捨てていません。"),
  summary_audio_changed: uiText("Recording bytes changed. Retry after uploads finish.", "録音データが変化しました。アップロード完了後に再試行してください。"),
  summary_audio_unavailable: uiText("Recording audio could not be read.", "録音音声を読み取れませんでした。"),
  summary_invalid_audio_model: uiText("Select an available audio-capable Gemini model in settings.", "設定で利用可能な音声対応Geminiモデルを選択してください。"),
};
type Job = components["schemas"]["SummaryJob"] | null;
const details = ["low", "medium", "high", "xhigh", "max"] as const;
const outputLanguages = { ja: "日本語", en: "English", zh: "中文", ko: "한국어", fr: "Français", de: "Deutsch", es: "Español" } as const;
const defaultLabel = (value: string) => `${value}${uiText(" (default)", "（既定）")}`;
const detailLabel = (detail: typeof details[number]) => ({ low: uiText("Concise", "簡潔"), medium: uiText("Standard", "標準"),
  high: uiText("Detailed", "詳細"), xhigh: uiText("Event session", "イベントセッション"), max: uiText("Event Play-by-Play", "イベント実況中継") })[detail];
const styleDescription = (style: WorkspaceGenerationSettings["summary"]["style"]) => ({
  concise: uiText("Decisions, issues, and next actions, with minimal detail.", "決定事項・課題・次のアクションを短くまとめます。"),
  standard: uiText("Main topics with enough context to understand them.", "主な話題を、必要な背景とともにバランスよくまとめます。"),
  detailed: uiText("Topics, background, reasoning, open questions, and next steps.", "話題ごとの背景・理由・未解決事項まで詳しく残します。"),
  eventSummary: uiText("Key claims, demonstrations, and takeaways from a talk or session.", "講演やセッションの主張・デモ・学びを流れに沿ってまとめます。"),
  eventTimeline: uiText("Follow an event in order, including demonstrations and Q&A.", "発言やデモ、質疑応答を時系列で詳しく辿れる形にします。"),
})[style];

function useSummaryMethods() {
  const capabilities = useLiveJSON<{
    meetingSummaryGeneration?: { version: number; sources: string[]; completeRecordings?: boolean };
  }>(apiQuery("getCapabilities", {}));
  const summary = capabilities.data?.meetingSummaryGeneration;
  return {
    ...capabilities,
    methods: summary?.version === 2 ? summary.sources : [],
    manualMethods: summary?.version === 2
      ? summary.sources.filter((source) => source !== "audio" || summary.completeRecordings === true)
      : [],
  };
}

export function ServerSummarySettings({ workspaceId, onSave }: {
  workspaceId: string;
  onSave: (workspace: components["schemas"]["Workspace"], settings: WorkspaceGenerationSettings) => Promise<unknown>;
}) {
  const capabilities = useSummaryMethods();
  const remoteSupported = capabilities.methods.length > 0;
  const remoteTranscriptionSupported = capabilities.methods.includes("audio");
  const query = useLiveJSON<components["schemas"]["Workspace"]>(apiQuery("getWorkspace", { params: { path: { workspaceId } } }));
  const [error, setError] = useState<string>();
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const catalog = useLiveJSON<GatewayModelList>(remoteSupported ? "/api/v1/models" : undefined, "manual");
  const isModelCatalogLoaded = !!catalog.data && !catalog.loading && !catalog.error;
  const settings = query.data?.generationSettings;
  const editingDisabled = saving || query.loading || !!query.error || query.data?.role !== "admin";

  const save = async (patch: Partial<WorkspaceGenerationSettings>) => {
    if (!query.data || !settings || editingDisabled) return;
    setSaving(true); setSaved(false); setError(undefined);
    try {
      await onSave(query.data, { ...settings, ...patch });
      query.replace(await api.getWorkspace({ params: { path: { workspaceId } } }));
      query.reload(); setSaved(true);
    }
    catch (error) { setError(error instanceof Error ? error.message : uiText("Could not save settings", "設定を保存できません")); query.reload(); }
    finally { setSaving(false); }
  };
  const summary = settings?.summary ?? DEFAULT_WORKSPACE_GENERATION_SETTINGS.summary;
  const processing = settings?.processing ?? DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing;
  const remote = processing.remote;
  const saveRemote = (value: Partial<typeof remote>) => save({ processing: { ...processing, remote: { ...remote, ...value } } });
  const audioModels = catalog.data?.data.filter((model) => model.id !== CODEX_AUTO_REVIEW_ALIAS
    && isSummaryModel(model.id, catalog.data!, "audio")) ?? [];
  const transcriptModels = catalog.data?.data.filter((model) => model.id !== CODEX_AUTO_REVIEW_ALIAS
    && isSummaryModel(model.id, catalog.data!, "transcript")) ?? [];
  const selectedAudioModel = audioModels.find((model) => model.id === remote.summaryModel || remote.summaryModel?.endsWith(`.${model.id}`));
  const transcriptSummaryModel = remote.transcriptSummaryModel ?? (processing.location === "local" ? remote.summaryModel : undefined);
  const transcriptSummaryEffort = remote.transcriptSummaryReasoningEffort ?? (processing.location === "local" ? remote.reasoningEffort : undefined);
  const selectedTranscriptModel = transcriptModels.find((model) => model.id === transcriptSummaryModel || transcriptSummaryModel?.endsWith(`.${model.id}`));
  const audioEfforts = catalog.data?.models.find((model) => model.slug === selectedAudioModel?.id)?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
  const transcriptEfforts = catalog.data?.models.find((model) => model.slug === selectedTranscriptModel?.id)?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
  if (!query.data) return <section className="section-block settings-section" aria-busy={query.loading}>
    {query.error ? <p className="error" role="alert">{uiText("Could not load workspace settings. Your saved preferences have not changed.", "ワークスペース設定を読み込めませんでした。保存済みの設定は変更されていません。")}
      <button className="secondary" onClick={query.reload}>{uiText("Retry", "再試行")}</button></p>
      : <p role="status">{uiText("Loading settings…", "設定を読み込み中…")}</p>}
  </section>;
  return <>
    {(saving || saved) && <p className="settings-save-status" role="status" data-saved={saved && !saving}>
      {saving ? uiText("Saving changes…", "変更を保存中…") : uiText("Changes saved", "変更を保存しました")}
    </p>}
    {(error || query.error) && <p role="alert" className="error">{error ?? query.error?.message} {query.error && <button className="secondary" onClick={query.reload}>{uiText("Retry", "再試行")}</button>}</p>}
    <section className="section-block settings-section">
      <h2 className="section-label">{uiText("Generated content language", "生成コンテンツの言語")}</h2>
      <fieldset className="account-settings" disabled={editingDisabled}>
        <label>{uiText("Output language", "出力言語")}<Select value={settings?.outputLanguage ?? DEFAULT_WORKSPACE_GENERATION_SETTINGS.outputLanguage}
          onValueChange={(value) => void save({ outputLanguage: value as WorkspaceGenerationSettings["outputLanguage"] })}>
          {Object.entries(outputLanguages).map(([id, name]) => <option key={id} value={id}>{name}</option>)}
        </Select></label>
        <p>{uiText("Shared by summaries and image descriptions. Speech recognition languages are unchanged.", "出力言語は要約と画像の説明に共通です。音声認識の言語は変更しません。")}</p>
      </fieldset>
    </section>
    <section className="section-block settings-section">
      <h2 className="section-label">{uiText("Transcription", "文字起こし")}</h2>
      <fieldset className="account-settings" disabled={editingDisabled}>
        <label>{uiText("Transcription location", "文字起こしの処理場所")}<Select value={processing.location}
          onValueChange={(value) => void save({ processing: { ...processing, location: value as WorkspaceGenerationSettings["processing"]["location"] } })}>
          <option value="local">{uiText("Dahlia for Mac", "Dahlia for Mac")}</option>
          {(remoteTranscriptionSupported || processing.location === "remote") && <option value="remote" disabled={!remoteTranscriptionSupported}>
            {uiText("Server", "サーバー")}</option>}
        </Select></label>
        {processing.location === "local" && <p>{uiText(
          "Language settings are configured on each device in Dahlia for Mac.",
          "言語は、各端末のDahlia for Macで設定します。",
        )}</p>}
        {processing.location === "remote" ? <p>{uiText(
          "Gemini detects the spoken language while transcribing. No language setting is required.",
          "Geminiが文字起こしの処理中に発話言語を判定するため、言語設定は不要です。",
        )}</p> : null}
        {capabilities.loading && <p role="status">{uiText("Checking server capabilities…", "サーバー機能を確認中…")}</p>}
        {!remoteTranscriptionSupported && !capabilities.loading && !capabilities.error && <p>{uiText("Server transcription is unavailable on this server.", "このサーバーでは文字起こしを実行できません。")}</p>}
        {capabilities.error && <p role="alert" className="error">{capabilities.error.message} <button className="secondary"
          onClick={capabilities.reload}>{uiText("Retry", "再試行")}</button></p>}
      </fieldset>
    </section>
    <section className="section-block settings-section">
      <h2 className="section-label">{uiText("Summary", "要約")}</h2>
      <fieldset className="account-settings" disabled={editingDisabled}>
        <p>{uiText("Summary processing: Server", "要約の処理場所：サーバー")}</p>
        <p>{uiText("The original transcript is synchronized and summarized on the server, including transcripts created in Dahlia for Mac.", "Dahlia for Macで作成した文字起こしも、原文を同期してからサーバーで要約します。")}</p>
        {!remoteSupported && !capabilities.loading && !capabilities.error && <p>{uiText("Summary generation is unavailable on this server.", "このサーバーでは要約生成を利用できません。")}</p>}
        <label>{uiText("Summary style", "まとめ方")}<Select value={summary.style}
          onValueChange={(value) => void save({ summary: { style: value as WorkspaceGenerationSettings["summary"]["style"] } })}>
          {summaryStyles.map((style) => <option key={style} value={style}>{detailLabel(summaryStyleDetail(style))}</option>)}
        </Select></label>
        <p>{styleDescription(summary.style)}</p>
        {processing.location === "remote" && <>
          <label>{uiText("Summary method", "要約方法")}<Select value={remote.workflow} disabled={!remoteSupported}
            onValueChange={(value) => void saveRemote({ workflow: value as typeof remote.workflow })}>
            <option value="transcribeThenSummarize">{uiText("Generate from transcript", "文字起こしから生成")}</option>
            <option value="combined">{uiText("Generate directly from audio", "音声から直接生成")}</option>
          </Select></label>
          <p>{remote.workflow === "combined" ? uiText(
            "For automatic processing after recording, Gemini creates the summary directly from the audio and produces a transcript in the same process.",
            "録音後の自動処理では、Geminiが音声から直接要約し、同じ処理内で文字起こしも作成します。",
          ) : uiText(
            "For automatic processing after recording, Gemini transcribes the audio first, then creates the summary from that transcript.",
            "録音後の自動処理では、Geminiが先に音声を文字起こしし、その文字起こしから要約を作成します。",
          )}</p>
        </>}
        {processing.location === "remote" && <>
          {isModelCatalogLoaded && remote.summaryModel && !selectedAudioModel && <p role="status">{uiText(
            "A selected model is unavailable. Change it or choose Automatic.",
            "利用できないモデルが指定されています。変更するか「自動」に戻してください。",
          )}</p>}
          <label>{uiText("Audio processing model", "音声処理モデル")}<Select value={selectedAudioModel?.id ?? remote.summaryModel ?? ""}
            disabled={catalog.loading || !remoteSupported} onValueChange={(value) => void saveRemote({ summaryModel: value || undefined })}>
            <option value="">{uiText("Automatic", "自動")}</option>
            {remote.summaryModel && !selectedAudioModel && <option value={remote.summaryModel} disabled>{remote.summaryModel}{isModelCatalogLoaded && ` — ${uiText("Unavailable for this workflow", "この方式では利用不可")}`}</option>}
            {audioModels.map((model) => <option key={model.id} value={model.id}>{model.display_name}</option>)}
          </Select></label>
          <label>{uiText("Audio processing reasoning effort", "音声処理の推論強度")}<Select value={remote.reasoningEffort ?? ""} disabled={!remoteSupported}
            onValueChange={(value) => void saveRemote({ reasoningEffort: value ? value as typeof remote.reasoningEffort : undefined })}>
            <option value="">{uiText("Automatic", "自動")}</option>
            {remote.reasoningEffort && !audioEfforts.includes(remote.reasoningEffort) && <option value={remote.reasoningEffort} disabled>{remote.reasoningEffort} — {uiText("Check model compatibility", "モデルとの対応を確認")}</option>}
            {audioEfforts.map((effort) => <option key={effort}>{effort}</option>)}
          </Select></label>
        </>}
        {(processing.location === "local" || remote.workflow === "transcribeThenSummarize") && <>
          {isModelCatalogLoaded && transcriptSummaryModel && !selectedTranscriptModel && <p role="status">{uiText(
            "A selected model is unavailable. Change it or choose Automatic.",
            "利用できないモデルが指定されています。変更するか「自動」に戻してください。",
          )}</p>}
          <label>{uiText("Summary model", "要約モデル")}<Select value={selectedTranscriptModel?.id ?? transcriptSummaryModel ?? ""}
            disabled={catalog.loading || !remoteSupported} onValueChange={(value) => void saveRemote({
              transcriptSummaryModel: value || undefined,
              ...(processing.location === "local" ? { summaryModel: undefined } : {}),
            })}>
            <option value="">{uiText("Automatic", "自動")}</option>
            {transcriptSummaryModel && !selectedTranscriptModel && <option value={transcriptSummaryModel} disabled>{transcriptSummaryModel}{isModelCatalogLoaded && ` — ${uiText("Unavailable for this workflow", "この方式では利用不可")}`}</option>}
            {transcriptModels.map((model) => <option key={model.id} value={model.id}>{model.display_name}</option>)}
          </Select></label>
          <label>{uiText("Summary reasoning effort", "要約の推論強度")}<Select value={transcriptSummaryEffort ?? ""} disabled={!remoteSupported}
            onValueChange={(value) => void saveRemote({
              transcriptSummaryReasoningEffort: value ? value as typeof remote.transcriptSummaryReasoningEffort : undefined,
              ...(processing.location === "local" ? { reasoningEffort: undefined } : {}),
            })}>
            <option value="">{uiText("Automatic", "自動")}</option>
            {transcriptSummaryEffort && !transcriptEfforts.includes(transcriptSummaryEffort) && <option value={transcriptSummaryEffort} disabled>{transcriptSummaryEffort} — {uiText("Check model compatibility", "モデルとの対応を確認")}</option>}
            {transcriptEfforts.map((effort) => <option key={effort}>{effort}</option>)}
          </Select></label>
        </>}
        {catalog.error && <p role="alert" className="error">{catalog.error.message}</p>}
        {isModelCatalogLoaded && ((processing.location === "remote" && !audioModels.length)
          || ((processing.location === "local" || remote.workflow === "transcribeThenSummarize") && !transcriptModels.length))
          && <p>{uiText("No models available", "利用可能なモデルがありません")}</p>}
        <button className="secondary" onClick={catalog.reload} disabled={catalog.loading || !remoteSupported}>{uiText("Reload models", "モデル一覧を再取得")}</button>
      </fieldset>
    </section>
    <section className="section-block settings-section">
      <h2 className="section-label">{uiText("After recording", "録音後の自動処理")}</h2>
      <fieldset className="account-settings" disabled={editingDisabled}>
        <label className="switch-field"><span>{uiText("Automatically transcribe and summarize after recording", "録音終了後に文字起こし・要約を自動実行")}</span>
          <input type="checkbox" role="switch" checked={settings?.automaticProcessing ?? true}
            onChange={(event) => void save({ automaticProcessing: event.target.checked })} />
          <span className="switch-control" aria-hidden="true" />
        </label>
      </fieldset>
    </section>
  </>;
}

export function ServerSummaryGeneration({ meetingId, workspaceId }: { meetingId: string; workspaceId: string }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const methods = useSummaryMethods().manualMethods;
  const enabled = methods.length > 0;
  const catalog = useLiveJSON<GatewayModelList>(enabled ? "/api/v1/models" : undefined, "manual");
  const query = useLiveJSON<{ job: Job }>(enabled ? apiQuery("getLatestSummaryJob", { params: { path: { meetingId } } }) : undefined);
  const workspaceQuery = useLiveJSON<components["schemas"]["Workspace"]>(apiQuery("getWorkspace", { params: { path: { workspaceId } } }));
  const transcriptQuery = useLiveJSON<TranscriptSnapshot>(methods.includes("transcript") ? {
    key: JSON.stringify(["summaryTranscriptAvailability", { meetingId }]),
    load: (signal) => loadTranscript(meetingId, signal),
  } : undefined);
  const recordingsQuery = useLiveJSON<RecordingSnapshot>(methods.includes("audio") ? {
    key: JSON.stringify(["summaryRecordingAvailability", { meetingId }]),
    load: (signal) => loadRecordings(meetingId, signal),
  } : undefined);
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string>();
  const [detail, setDetail] = useState("");
  const [language, setLanguage] = useState("");
  const [model, setModel] = useState<string>();
  const [effort, setEffort] = useState<string>();
  const [source, setSource] = useState<SummarySource>();
  const completed = useRef<string | undefined>(undefined);
  const requestID = useRef<string | undefined>(undefined);
  const requestBody = useRef<SummaryRequest | undefined>(undefined);
  const job = query.data?.job;
  function clearPendingRequest() {
    requestID.current = undefined;
    requestBody.current = undefined;
  }
  useEffect(() => {
    if (!enabled) return;
    const timer = window.setInterval(query.reload, 5000);
    return () => window.clearInterval(timer);
  }, [enabled, meetingId]); // reload uses the query's current queue.
  useEffect(() => {
    if (job?.id === requestID.current) clearPendingRequest();
    if (job?.status === "succeeded" && completed.current !== job.id) {
      completed.current = job.id; refreshData();
    }
  }, [job?.id, job?.status]);
  const active = job?.status === "pending" || job?.status === "processing";
  const transcriptAvailable = methods.includes("transcript") && !transcriptQuery.loading && !transcriptQuery.error
    && transcriptQuery.data?.available === true;
  const audioAvailable = methods.includes("audio") && !recordingsQuery.loading && !recordingsQuery.error
    && recordingsQuery.data?.complete === true;
  const sourceAvailable = (candidate: SummarySource) => candidate === "transcript" ? transcriptAvailable : audioAvailable;
  let preferredSource: SummarySource | undefined;
  if (!methods.includes("transcript") || (!transcriptQuery.loading && !transcriptQuery.error)) {
    if (transcriptAvailable) preferredSource = "transcript";
    else if (audioAvailable) preferredSource = "audio";
  }
  const selectedSource = source ?? preferredSource;
  const selectedSourceAvailable = selectedSource ? sourceAvailable(selectedSource) : false;
  const models = catalog.data?.data.filter((entry) => entry.id !== CODEX_AUTO_REVIEW_ALIAS
    && isSummaryModel(entry.id, catalog.data!, selectedSource ?? "transcript")) ?? [];
  const workspaceSettings = workspaceQuery.data?.generationSettings;
  const savedModelID = selectedSource === "audio" ? workspaceSettings?.processing.remote.summaryModel
    : workspaceSettings?.processing.remote.transcriptSummaryModel
      ?? (workspaceSettings?.processing.location === "local" ? workspaceSettings.processing.remote.summaryModel : undefined);
  const savedEffort = selectedSource === "audio" ? workspaceSettings?.processing.remote.reasoningEffort
    : workspaceSettings?.processing.remote.transcriptSummaryReasoningEffort
      ?? (workspaceSettings?.processing.location === "local" ? workspaceSettings.processing.remote.reasoningEffort : undefined);
  const defaultModelID = savedModelID;
  const selectedModelID = model ?? defaultModelID ?? "";
  const modelForID = (id: string | undefined) => models.find((entry) => entry.id === id || id?.endsWith(`.${entry.id}`));
  const selectedModel = modelForID(selectedModelID);
  const defaultModel = modelForID(defaultModelID);
  const isModelUnavailable = !!selectedSource && !!catalog.data && !catalog.loading && !catalog.error && !!selectedModelID && !selectedModel;
  const efforts = catalog.data?.models.find((entry) => entry.slug === selectedModel?.id)?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
  const defaultEffort = savedEffort;
  const selectedEffort = effort ?? defaultEffort ?? "";
  const defaultLanguage = workspaceSettings?.outputLanguage;
  const defaultDetail = workspaceSettings ? summaryStyleDetail(workspaceSettings.summary.style) : undefined;
  const defaultModelLabel = defaultLabel(defaultModel?.display_name ?? defaultModelID ?? uiText("Automatic", "自動"))
    + (isModelUnavailable && model === undefined ? ` — ${uiText("Unavailable", "利用不可")}` : "");

  const sourceReason = (candidate: SummarySource) => {
    if (!methods.includes(candidate)) return uiText("This server does not support this source.", "このサーバーはこのソースに対応していません。");
    const state = candidate === "transcript" ? transcriptQuery : recordingsQuery;
    if (state.loading) return uiText("Checking availability…", "利用可能か確認中…");
    if (state.error) return candidate === "audio" && state.error instanceof RequestError && state.error.status === 409
      ? uiText("Some recording audio is still uploading.", "一部の録音音声がアップロード中です。")
      : uiText("Availability could not be confirmed.", "利用可能か確認できませんでした。");
    if (candidate === "transcript" && !transcriptAvailable) return uiText(
      "The latest transcript is empty or has not been saved.", "最新の文字起こしが空か、まだ保存されていません。",
    );
    if (candidate === "audio" && !audioAvailable) return recordingsQuery.data?.items?.length
      ? uiText("Some recording audio is still uploading.", "一部の録音音声がアップロード中です。")
      : uiText("No committed recording audio is available.", "確定済みの録音音声がありません。");
  };
  const start = async () => {
    setStarting(true); setError(undefined);
    requestID.current ??= encodeId("summaryJob", uuidV7());
    try {
      if (!requestBody.current) {
        const workspace = await api.getWorkspace({ params: { path: { workspaceId } } });
        const settings = workspace.generationSettings;
        if (!selectedSource) throw new Error(uiText("Choose an available source.", "利用可能なソースを選択してください。"));
        let input: Extract<SummaryRequest, { input: unknown }>["input"];
        if (selectedSource === "transcript") {
          const transcript = await loadTranscript(meetingId);
          if (!transcript.available) throw new Error(uiText(
            "The latest transcript is empty or has not been saved.", "最新の文字起こしが空か、まだ保存されていません。",
          ));
          input = { type: "transcript", version: String(transcript.version) };
        } else {
          const snapshot = await loadRecordings(meetingId);
          if (!snapshot.complete) throw new Error(snapshot.items.length
            ? uiText("Some recording audio is still uploading.", "一部の録音音声がアップロード中です。")
            : summaryErrors.summary_audio_empty!);
          input = { type: "recording", recordings: snapshot.recordings };
        }
        const remote = { ...settings.processing.remote,
          workflow: selectedSource === "audio" ? "combined" as const : "transcribeThenSummarize" as const };
        if (selectedSource === "audio") {
          if (model !== undefined) remote.summaryModel = model || undefined;
          if (effort !== undefined) remote.reasoningEffort = effort ? effort as typeof remote.reasoningEffort : undefined;
        } else {
          if (model !== undefined) remote.transcriptSummaryModel = model || undefined;
          if (effort !== undefined) remote.transcriptSummaryReasoningEffort = effort ? effort as typeof remote.transcriptSummaryReasoningEffort : undefined;
        }
        requestBody.current = { id: requestID.current, input,
          preferences: { processing: { location: "remote", remote }, outputLanguage: (language || settings.outputLanguage) as WorkspaceGenerationSettings["outputLanguage"],
            summary: { style: detail ? summaryStyles[details.indexOf(detail as typeof details[number])]! : settings.summary.style } } };
      }
      await api.startSummaryJob({ params: { path: { meetingId } }, body: requestBody.current });
      clearPendingRequest(); query.reload();
    } catch (error) {
      if (error instanceof RequestError && error.status === 400) {
        clearPendingRequest();
        transcriptQuery.reload(); recordingsQuery.reload();
      }
      setError(error instanceof Error ? summaryErrors[error.message] ?? error.message : uiText("Could not start summary", "要約を開始できません")); query.reload();
    }
    finally { setStarting(false); }
  };
  const action = async (action: "cancel" | "retry") => {
    if (!job) return;
    setStarting(true); setError(undefined);
    requestID.current ??= encodeId("summaryJob", uuidV7());
    try {
      const params = { path: { meetingId, jobId: job.id } };
      if (action === "retry") await api.retrySummaryJob({ params, body: { id: requestID.current } });
      else await api.cancelSummaryJob({ params });
      clearPendingRequest(); query.reload();
    } catch (error) { setError(error instanceof Error ? error.message : String(error)); }
    finally { setStarting(false); }
  };
  let buttonLabel = uiText("Generate summary", "要約を生成");
  if (active) buttonLabel = uiText("Generating on server…", "サーバーで生成中…");


  let failureMessage: string | undefined;
  if (job?.status === "failed") {
    if (job.error && summaryErrors[job.error]) failureMessage = summaryErrors[job.error];
    else if (job.error === "summary_input_changed") {
      failureMessage = uiText("Inputs changed during generation. Retry after processing and uploads finish.", "生成中に入力が更新されました。処理・アップロードの完了後に再試行してください。");
    } else {
      failureMessage = uiText("Summary failed; the existing summary was preserved.", "要約の生成に失敗しました。既存の要約は保持されています。");
    }
  }

  const title = uiText("Generate AI summary", "AI 要約を生成");
  return <>
    <button type="button" className="summary-generation-trigger icon-button" title={title} aria-label={title}
      onClick={() => dialog.current?.showModal()}><MenuIcon name="sparkles" /></button>
    <dialog ref={dialog} className="action-dialog action-dialog-wide summary-generation-dialog" aria-labelledby={`summary-generation-title-${meetingId}`}
      onClick={(event) => {
        if (event.detail !== 1) return;
        const rect = event.currentTarget.getBoundingClientRect();
        if (event.target === event.currentTarget && (event.clientX < rect.left || event.clientX > rect.right
          || event.clientY < rect.top || event.clientY > rect.bottom)) event.currentTarget.close();
      }}>
      <header className="dialog-header"><div><span className="dialog-symbol" aria-hidden="true"><MenuIcon name="sparkles" /></span>
        <h2 id={`summary-generation-title-${meetingId}`}>{uiText("AI summary", "AI 要約")}</h2></div>
        <button type="button" className="icon-button" aria-label={uiText("Close", "閉じる")} onClick={() => dialog.current?.close()}>×</button>
      </header>
      <div className="dialog-body"><p className="dialog-description">{uiText("Turn this conversation into clear next steps.", "会話のポイントと、次のアクションを整理します。")}</p>
      <div className="summary-generation">
    <fieldset className="summary-source-options" disabled={active || starting} aria-busy={transcriptQuery.loading || recordingsQuery.loading}>
      <legend>{uiText("Source for this generation", "今回の生成ソース")}</legend>
      <div>
        {(["transcript", "audio"] as const).map((candidate) => {
          const isTranscript = candidate === "transcript";
          const available = sourceAvailable(candidate);
          const reason = sourceReason(candidate);
          const option = <label data-disabled={!available} tabIndex={reason ? 0 : undefined}>
            <input type="radio" name={`summary-source-${meetingId}`} value={candidate} checked={selectedSource === candidate}
              disabled={!available} onChange={() => { setSource(candidate); setModel(undefined); setEffort(undefined); clearPendingRequest(); }} />
            <span><strong>{isTranscript ? uiText("Transcript (text)", "文字起こし（テキスト）") : uiText("Recording files (audio)", "録音ファイル（音声）")}</strong>
              <small>{isTranscript
                ? uiText("Regenerate only the summary from the latest transcript.", "最新の文字起こしから要約だけを再生成します。")
                : uiText("Regenerate both the transcript and summary from all recordings.", "すべての録音から文字起こしと要約を再生成します。")}</small>
            </span>
          </label>;
          return reason
            ? <Tooltip key={candidate} className="summary-source-tooltip" label={reason}>{option}</Tooltip>
            : <span key={candidate} className="summary-source-option">{option}</span>;
        })}
      </div>
    </fieldset>
    <fieldset disabled={!enabled || active || starting || workspaceQuery.loading} className="account-settings summary-generation-options">
      <legend>{uiText("Summary options", "要約生成オプション")}</legend>
      <div className="summary-generation-settings">
      <label>{uiText("Summary language", "要約の言語")}<Select value={language} onValueChange={(value) => { setLanguage(value); clearPendingRequest(); }}>
        <option value="">{defaultLabel(defaultLanguage ? outputLanguages[defaultLanguage] : uiText("Loading…", "読み込み中…"))}</option>
        {Object.entries(outputLanguages).map(([id, name]) => <option key={id} value={id}>{name}</option>)}
      </Select></label>
      <label>{uiText("Summary detail", "要約の詳細度")}<Select value={detail}
        onValueChange={(value) => { setDetail(value); clearPendingRequest(); }}>
        <option value="">{defaultLabel(defaultDetail ? detailLabel(defaultDetail) : uiText("Loading…", "読み込み中…"))}</option>
        {details.map((detail) => <option key={detail} value={detail}>{detailLabel(detail)}</option>)}
      </Select></label>
      <label>{uiText("Summary model", "要約モデル")}<Select value={model === undefined ? "__default" : model} disabled={catalog.loading}
        onValueChange={(value) => {
          const useDefaults = value === "__default";
          setModel(useDefaults ? undefined : value);
          setEffort(useDefaults ? undefined : "");
          clearPendingRequest();
        }}>
        <option value="__default">{defaultModelLabel}</option>
        <option value="">{uiText("Automatic", "自動")}</option>
        {model && !selectedModel && <option value={selectedModelID} disabled>{selectedModelID}{isModelUnavailable && ` — ${uiText("Unavailable", "利用不可")}`}</option>}
        {models.map((entry) => <option key={entry.id} value={entry.id}>{entry.display_name}</option>)}
      </Select></label>
      <label>{uiText("Reasoning effort", "推論強度")}<Select value={effort === undefined ? "__default" : effort}
        onValueChange={(value) => { setEffort(value === "__default" ? undefined : value); clearPendingRequest(); }}>
        <option value="__default" disabled={model !== undefined}>{defaultLabel(defaultEffort ?? uiText("Automatic", "自動"))}</option>
        <option value="">{uiText("Automatic", "自動")}</option>
        {effort && selectedEffort && !efforts.includes(selectedEffort) && <option value={selectedEffort} disabled>{selectedEffort} — {uiText("Check model compatibility", "モデルとの対応を確認")}</option>}
        {efforts.map((effort) => <option key={effort}>{effort}</option>)}
      </Select></label>
      </div>
      {catalog.error && <p role="alert">{catalog.error.message}</p>}
      <button className="secondary" disabled={!enabled || catalog.loading} onClick={catalog.reload}>{uiText("Reload models", "モデル一覧を再取得")}</button>
    </fieldset>
    <div className="generation-controls">
    <button className="primary" disabled={starting || active || query.loading || workspaceQuery.loading || !selectedSourceAvailable || isModelUnavailable} onClick={() => void start()}>
      {starting ? uiText("Starting…", "開始中…") : buttonLabel}
    </button>
    </div>
    {active && <><span role="status">{stageLabel(job.stage)} — {uiText("You can close this window.", "画面を閉じても処理は続きます。")}</span>
      <button disabled={starting} onClick={() => void action("cancel")}>{uiText("Cancel", "キャンセル")}</button></>}
    {(job?.status === "failed" || job?.status === "cancelled") && <button disabled={starting} onClick={() => void action("retry")}>
      {uiText("Retry with the same settings", "同じ設定で再試行")}</button>}
    {job?.status === "cancelled" && <span role="status">{uiText("Cancelled", "キャンセル済み")}</span>}
    {job?.status === "failed" && <span role="alert">{stageLabel(job.stage)}: {failureMessage}
      {job.error && <> ({job.error})</>}</span>}
    {(error || query.error) && <span role="alert">{error ?? query.error?.message}</span>}
      </div></div>
    </dialog>
  </>;
}

function stageLabel(stage: NonNullable<Job>["stage"]) {
  switch (stage) {
    case "transcribing": return uiText("Transcribing", "文字起こし中");
    case "summarizing": return uiText("Summarizing", "要約中");
    case "generating": return uiText("Generating transcription and summary", "文字起こし・要約を生成中");
    case "saving": return uiText("Saving results", "結果を保存中");
    default: return uiText("Waiting", "待機中");
  }
}

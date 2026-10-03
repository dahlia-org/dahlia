import { flushMeetingDocument } from "./Documents";
import { apiOperations as api } from "../api/generated-operations";
import type { components, operations } from "../api/generated-api";
import { apiQuery } from "../api/live-data";
import { Select } from "../components/Select";
import { MenuIcon } from "./Sidebar";
import { Tooltip } from "../components/Tooltip";
import { useEffect, useRef, useState } from "react";
import { RequestError, uiText } from "../api/api";
import { refreshData, useLiveJSON } from "../api/live-data";
import { encodeId } from "../model/typeid";
import { uuidV7 } from "../model/id";
import { pickerModels } from "../model/chat-models";
import type { GatewayModelList } from "../model/gateway-models";
import { DEFAULT_WORKSPACE_GENERATION_SETTINGS, summaryStyles, summaryStyleDetail, type WorkspaceGenerationSettings } from "../model/workspace-generation-settings";
type SummaryRequest = operations["startSummaryJob"]["requestBody"]["content"]["application/json"];
import { isSummaryModel } from "../model/summary-models";
import { CODEX_AUTO_REVIEW_ALIAS } from "../model/model-alias";
import { Button } from "../components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "../components/ui/dialog";

type SummarySource = "transcript" | "audio";
type Recording = components["schemas"]["Recording"];
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
  const page = await api.getLatestTranscript({ signal, params: { path: { meetingId }, query: { manifest: "1" } } });
  return { version: page.version, available: page.hasText === true };
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

function findSummaryModel(models: GatewayModelList["data"], id?: string) {
  return models.find((entry) => entry.id === id || id?.endsWith(`.${entry.id}`));
}

function useSummaryMethods() {
  const capabilities = useLiveJSON<{
    meetingSummaryGeneration?: { version: number; sources: string[]; completeRecordings?: boolean };
    ai?: { bundledModels?: "codex" };
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
  const query = useLiveJSON<components["schemas"]["Workspace"]>(apiQuery("getWorkspace", { params: { path: { workspaceId } } }));
  const [error, setError] = useState<string>();
  const [saving, setSaving] = useState(false);
  const workspace = query.data;
  const capabilities = useSummaryMethods();
  const methods = capabilities.manualMethods;
  const catalog = useLiveJSON<GatewayModelList>(methods.length ? "/api/v1/models" : undefined, "manual");
  const save = async (settings: WorkspaceGenerationSettings) => {
    if (!workspace) return;
    setSaving(true); setError(undefined);
    try {
      await onSave(workspace, settings);
      query.reload();
    } catch (error) { setError(error instanceof Error ? error.message : String(error)); }
    finally { setSaving(false); }
  };
  if (!workspace) return <section className="section-block">
    {query.refreshing && <p role="status">{uiText("Loading…", "読み込み中…")}</p>}
    {query.error && <p role="alert" className="error">{query.error.message}
      <button onClick={query.reload}>{uiText("Retry", "再試行")}</button></p>}
  </section>;
  const settings = workspace.generationSettings;
  const remote = settings.processing.remote;
  const imageAnalysis = settings.imageAnalysis;
  const imageControlsDisabled = catalog.loading || imageAnalysis?.enabled === false;
  const imageModels = catalog.data && pickerModels(catalog.data, capabilities.data?.ai?.bundledModels === "codex")
    .filter((entry) => entry.slug !== CODEX_AUTO_REVIEW_ALIAS && Array.isArray(entry.input_modalities) && entry.input_modalities.includes("image"));
  const imageEfforts = imageModels?.find((entry) => entry.slug === imageAnalysis?.model)?.supported_reasoning_levels
    .filter(({ effort }) => effort !== imageAnalysis?.reasoningEffort);
  const supportsAudio = methods.includes("audio");
  const combined = supportsAudio && remote.workflow === "combined";
  const sources: SummarySource[] = [];
  if (supportsAudio) sources.push("audio");
  // Two-stage audio generation also needs a text summary model.
  if (!combined && (supportsAudio || methods.includes("transcript"))) sources.push("transcript");
  const saveRemote = (next: Partial<typeof remote>) => void save({ ...settings, processing: { ...settings.processing, remote: { ...remote, ...next } } });
  return <>
  <section className="workspace-settings">
    <h2>{uiText("Generated content language", "生成コンテンツの言語")}</h2>
    <fieldset className="account-settings" disabled={saving || query.refreshing || !!query.error || workspace.role !== "admin"}>
      <label>{uiText("Output language", "出力言語")}<Select value={settings.outputLanguage}
        onValueChange={(value) => void save({ ...settings, outputLanguage: value as WorkspaceGenerationSettings["outputLanguage"] })}>
        {Object.entries(outputLanguages).map(([id, name]) => <option key={id} value={id}>{name}</option>)}
      </Select></label>
      <p>{uiText("Shared by summaries and image descriptions. Desktop transcription and summaries run on the Mac with account settings stored on that Mac. Web operations run on the server using the defaults below, with overrides available when starting them.",
        "要約と画像の説明に共通です。デスクトップの文字起こし・要約はMacで実行し、AI設定はそのMacのアカウントごとに保存します。Webからの処理はサーバーで実行し、下の既定設定を使用します。実行時に変更もできます。")}</p>
    </fieldset>
    {query.refreshing && <p role="status">{uiText("Loading…", "読み込み中…")}</p>}
    {(error || query.error) && <p role="alert" className="error">{error ?? query.error?.message}
      <button onClick={query.reload}>{uiText("Retry", "再試行")}</button></p>}
  </section>
  {(methods.length > 0 || capabilities.loading || capabilities.error) && <section className="workspace-settings">
    <h2>{uiText("Server generation defaults", "サーバー生成の既定設定")}</h2>
    {capabilities.loading && <p role="status">{uiText("Loading…", "読み込み中…")}</p>}
    {capabilities.error && <p role="alert" className="error">{capabilities.error.message}
      <button onClick={capabilities.reload}>{uiText("Retry", "再試行")}</button></p>}
    {methods.length > 0 && <fieldset className="account-settings" disabled={saving || query.refreshing || !!query.error || !!capabilities.error || workspace.role !== "admin"}>
      <p>{uiText("Used only when generating from Web. Desktop normally generates on the Mac and syncs the results; receiving them does not start server generation.", "Webから生成するときに使用します。通常はデスクトップで生成した結果を受け取ります。結果の受信をきっかけにサーバーで自動生成はしません。")}</p>
      {supportsAudio && <label>{uiText("Audio processing method", "音声の処理方法")}<Select value={remote.workflow}
        onValueChange={(workflow) => saveRemote({ workflow: workflow as typeof remote.workflow })}>
        <option value="combined">{uiText("Transcribe and summarize together", "文字起こし・要約を一括生成")}</option>
        <option value="transcribeThenSummarize">{uiText("Transcribe, then summarize", "文字起こし後に要約")}</option>
      </Select></label>}
      {sources.map((source) => {
        const isSummary = combined || source === "transcript";
        const modelKey = source === "audio" ? "summaryModel" : "transcriptSummaryModel";
        const effortKey = source === "audio" ? "reasoningEffort" : "transcriptSummaryReasoningEffort";
        const models = catalog.data?.data.filter((entry) => entry.id !== CODEX_AUTO_REVIEW_ALIAS && isSummaryModel(entry.id, catalog.data!, source)) ?? [];
        const selected = findSummaryModel(models, remote[modelKey]);
        let modelLabel = uiText("Transcript summary model", "テキスト要約モデル");
        if (combined) modelLabel = uiText("Summary model", "要約モデル");
        else if (source === "audio") modelLabel = uiText("Audio processing model", "音声処理モデル");
        const efforts = catalog.data?.models.find((entry) => entry.slug === selected?.id)?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
        return <fieldset key={source} className="min-w-0 rounded-lg border bg-muted/30 p-4">
          <legend className="px-1 text-sm font-semibold">{isSummary ? uiText("Summary generation", "要約生成") : uiText("Transcription", "文字起こし")}</legend>
          {combined && <p className="mb-3">{uiText("Generate directly from audio with an audio-capable Gemini model.", "音声対応のGeminiモデルで、音声から直接生成します。")}</p>}
          <div className="grid gap-3 sm:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
          <label className="grid gap-1.5 text-sm">{modelLabel}
            <Select value={remote[modelKey] ?? ""} disabled={catalog.loading} onValueChange={(model) => saveRemote({ [modelKey]: model || undefined, [effortKey]: undefined })}>
              <option value="">{uiText("Automatic", "自動")}</option>
              {remote[modelKey] && !selected && <option value={remote[modelKey]} disabled>{remote[modelKey]}</option>}
              {models.map((entry) => <option key={entry.id} value={entry.id}>{entry.display_name}</option>)}
            </Select>
          </label>
          <label className="grid gap-1.5 text-sm">{isSummary ? uiText("Summary reasoning effort", "要約の推論強度") : uiText("Audio reasoning effort", "音声処理の推論強度")}
            <Select value={remote[effortKey] ?? ""} disabled={catalog.loading} onValueChange={(effort) => saveRemote({ [effortKey]: effort || undefined })}>
              <option value="">{uiText("Automatic", "自動")}</option>
              {remote[effortKey] && !efforts.includes(remote[effortKey]) && <option value={remote[effortKey]}>{remote[effortKey]}</option>}
              {efforts.map((effort) => <option key={effort}>{effort}</option>)}
            </Select>
          </label>
          </div>
          {isSummary && <label className="mt-4 grid gap-1.5 text-sm">{uiText("Summary style", "要約の詳細度")}<Select value={settings.summary.style}
            onValueChange={(style) => void save({ ...settings, summary: { style: style as typeof settings.summary.style } })}>
            {summaryStyles.map((style) => <option key={style} value={style}>{detailLabel(summaryStyleDetail(style))}</option>)}
          </Select></label>}
        </fieldset>;
      })}
      <fieldset className="min-w-0 rounded-lg border bg-muted/30 p-4">
        <legend className="px-1 text-sm font-semibold">{uiText("Image analysis", "画像解析")}</legend>
        <label className="mb-4 flex items-center gap-2 text-sm">
          <input className="h-4 w-4 shrink-0" type="checkbox" checked={imageAnalysis?.enabled ?? true}
            onChange={(event) => void save({ ...settings, imageAnalysis: { ...imageAnalysis, enabled: event.target.checked } })} />
          {uiText("Enable image analysis", "画像解析を有効にする")}
        </label>
        <div className="grid gap-3 sm:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
          <label className="grid gap-1.5 text-sm">{uiText("Image analysis model", "画像解析モデル")}
            <Select value={imageAnalysis?.model ?? ""} disabled={imageControlsDisabled}
              onValueChange={(model) => void save({ ...settings, imageAnalysis: { enabled: imageAnalysis?.enabled ?? true, model: model || undefined, reasoningEffort: undefined } })}>
              <option value="">{uiText("Server default", "サーバーの既定値")}</option>
              {imageAnalysis?.model && !imageModels?.some((entry) => entry.slug === imageAnalysis?.model)
                && <option value={imageAnalysis.model}>{imageAnalysis.model}</option>}
              {imageModels?.map((entry) => <option key={entry.slug} value={entry.slug}>{entry.display_name}</option>)}
            </Select>
          </label>
          <label className="grid gap-1.5 text-sm">{uiText("Image analysis reasoning effort", "画像解析の推論強度")}
            <Select value={imageAnalysis?.reasoningEffort ?? ""} disabled={imageControlsDisabled}
              onValueChange={(effort) => void save({ ...settings, imageAnalysis: { ...imageAnalysis, enabled: imageAnalysis?.enabled ?? true, reasoningEffort: effort as typeof remote.reasoningEffort || undefined } })}>
              <option value="">{uiText("Automatic", "自動")}</option>
              {imageAnalysis?.reasoningEffort && <option value={imageAnalysis.reasoningEffort}>{imageAnalysis.reasoningEffort}</option>}
              {imageEfforts?.map(({ effort }) => <option key={effort} value={effort}>{effort}</option>)}
            </Select>
          </label>
        </div>
      </fieldset>
      {catalog.error && <p role="alert" className="error">{catalog.error.message}</p>}
      <button disabled={catalog.loading} onClick={catalog.reload}>{uiText("Reload models", "モデル一覧を再取得")}</button>
    </fieldset>}
  </section>}
  </>;
}

export function SummaryGenerationSurface({ meetingId, workspaceId, hasSummary = false }: {
  meetingId: string;
  workspaceId: string;
  hasSummary?: boolean;
}) {
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
  const [audioModel, setAudioModel] = useState<string>();
  const [audioEffort, setAudioEffort] = useState<string>();
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
  const workspaceSettings = workspaceQuery.data?.generationSettings;
  const twoStageAudio = selectedSource === "audio" && workspaceSettings?.processing.remote.workflow === "transcribeThenSummarize";
  const modelOptions = (twoStageAudio ? [true, false] : [false]).map((transcription) => {
    const audio = transcription || (selectedSource === "audio" && !twoStageAudio);
    const defaultModel = audio ? workspaceSettings?.processing.remote.summaryModel : workspaceSettings?.processing.remote.transcriptSummaryModel;
    const defaultEffort = audio ? workspaceSettings?.processing.remote.reasoningEffort : workspaceSettings?.processing.remote.transcriptSummaryReasoningEffort;
    const value = transcription ? audioModel : model;
    const effortValue = transcription ? audioEffort : effort;
    const models = catalog.data?.data.filter((entry) => entry.id !== CODEX_AUTO_REVIEW_ALIAS
      && isSummaryModel(entry.id, catalog.data!, audio ? "audio" : "transcript")) ?? [];
    const selectedModelID = value ?? defaultModel ?? "";
    const selectedModel = findSummaryModel(models, selectedModelID);
    const unavailable = !!selectedSource && !!catalog.data && !catalog.loading && !catalog.error && !!selectedModelID && !selectedModel;
    const efforts = catalog.data?.models.find((entry) => entry.slug === selectedModel?.id)?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
    const defaultModelName = defaultModel ? findSummaryModel(models, defaultModel)?.display_name ?? defaultModel : uiText("Automatic", "自動");
    return { transcription, defaultEffort, value, effortValue, models, selectedModelID, selectedModel, unavailable, efforts, defaultModelName,
      setModel: transcription ? setAudioModel : setModel, setEffort: transcription ? setAudioEffort : setEffort };
  });
  const isModelUnavailable = modelOptions.some((option) => option.unavailable);
  const defaultLanguage = workspaceSettings?.outputLanguage;
  const defaultDetail = summaryStyleDetail(workspaceSettings?.summary.style ?? DEFAULT_WORKSPACE_GENERATION_SETTINGS.summary.style);
  const automaticDefaultLabel = defaultLabel(uiText("Automatic", "自動"));

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
        const remote: WorkspaceGenerationSettings["processing"]["remote"] = {
          ...settings.processing.remote,
          workflow: selectedSource === "audio" ? workspaceSettings?.processing.remote.workflow ?? settings.processing.remote.workflow : "transcribeThenSummarize" };
        if (selectedSource === "transcript") {
          delete remote.summaryModel; delete remote.reasoningEffort;
        }
        if (twoStageAudio) {
          if (audioModel !== undefined) remote.summaryModel = audioModel || undefined;
          if (audioEffort !== undefined) remote.reasoningEffort = audioEffort ? audioEffort as typeof remote.reasoningEffort : undefined;
        }
        if (selectedSource === "audio" && !twoStageAudio) {
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
      await flushMeetingDocument(workspaceId, meetingId);
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
      if (action === "retry") await flushMeetingDocument(workspaceId, meetingId);
      if (action === "retry") await api.retrySummaryJob({ params, body: { id: requestID.current } });
      else await api.cancelSummaryJob({ params });
      clearPendingRequest(); query.reload();
    } catch (error) { setError(error instanceof Error ? error.message : String(error)); }
    finally { setStarting(false); }
  };
  let buttonLabel = hasSummary ? uiText("Regenerate summary", "要約を再生成") : uiText("Generate summary", "要約を生成");
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

  return <div className="grid gap-5">
    <fieldset className="grid gap-2 border-0 p-0" disabled={active || starting} aria-busy={transcriptQuery.loading || recordingsQuery.loading}>
      <legend className="mb-2 text-sm font-medium">{uiText("Source for this generation", "今回の生成ソース")}</legend>
      <div className="grid gap-2 sm:grid-cols-2">
        {(["transcript", "audio"] as const).map((candidate) => {
          const isTranscript = candidate === "transcript";
          const available = sourceAvailable(candidate);
          const reason = sourceReason(candidate);
          const option = <label className="flex min-h-20 cursor-pointer items-start gap-3 rounded-lg border p-3 text-sm has-[:checked]:border-primary has-[:checked]:bg-accent/50 data-[disabled=true]:cursor-not-allowed data-[disabled=true]:opacity-50"
            data-disabled={!available} aria-label={reason} tabIndex={reason ? 0 : undefined}>
            <input className="mt-1 size-4 accent-primary" type="radio" name={`summary-source-${meetingId}`} value={candidate} checked={selectedSource === candidate}
              disabled={!available} onChange={() => { setSource(candidate); setModel(undefined); setEffort(undefined); setAudioModel(undefined); setAudioEffort(undefined); clearPendingRequest(); }} />
            <span className="grid gap-1"><strong>{isTranscript ? uiText("Transcript (text)", "文字起こし（テキスト）") : uiText("Recording files (audio)", "録音ファイル（音声）")}</strong>
              <small className="leading-5 text-muted-foreground">{isTranscript
                ? uiText("Regenerate only the summary from the latest transcript.", "最新の文字起こしから要約だけを再生成します。")
                : uiText("Regenerate both the transcript and summary from all recordings.", "すべての録音から文字起こしと要約を再生成します。")}</small>
            </span>
          </label>;
          return reason
            ? <Tooltip key={candidate} className="w-full" label={reason}>{option}</Tooltip>
            : <span key={candidate}>{option}</span>;
        })}
      </div>
    </fieldset>
    <fieldset disabled={!enabled || active || starting || workspaceQuery.loading} className="grid gap-3 border-0 p-0">
      <legend className="mb-2 text-sm font-medium">{uiText("Summary options", "要約生成オプション")}</legend>
      <div className="grid gap-3 sm:grid-cols-2">
      <label className="grid gap-1.5 text-xs font-medium text-muted-foreground">{uiText("Summary language", "要約の言語")}<Select value={language} onValueChange={(value) => { setLanguage(value); clearPendingRequest(); }}>
        <option value="">{defaultLabel(defaultLanguage ? outputLanguages[defaultLanguage] : uiText("Loading…", "読み込み中…"))}</option>
        {Object.entries(outputLanguages).map(([id, name]) => <option key={id} value={id}>{name}</option>)}
      </Select></label>
      </div>
      {modelOptions.map(({ transcription, value, effortValue, defaultEffort, defaultModelName, models, selectedModelID, selectedModel, unavailable, efforts, setModel, setEffort }) => <fieldset key={String(transcription)} className="grid gap-3 rounded-lg border bg-muted/20 p-4">
      <legend className="px-1 text-sm font-medium">{transcription ? uiText("Transcription", "文字起こし") : uiText("Summary generation", "要約生成")}</legend>
      <div className="grid gap-3 sm:grid-cols-2">
      <label className="grid gap-1.5 text-xs font-medium text-muted-foreground">{transcription ? uiText("Transcription model", "文字起こしモデル") : uiText("Summary model", "要約モデル")}<Select value={value === undefined ? "__default" : value} disabled={catalog.loading}
        onValueChange={(value) => {
          const useDefaults = value === "__default";
          setModel(useDefaults ? undefined : value);
          setEffort(useDefaults ? undefined : "");
          clearPendingRequest();
        }}>
        <option value="__default">{defaultLabel(defaultModelName)}{value === undefined && unavailable && ` — ${uiText("Unavailable", "利用不可")}`}</option>
        <option value="">{uiText("Automatic", "自動")}</option>
        {value && !selectedModel && <option value={selectedModelID} disabled>{selectedModelID}{unavailable && ` — ${uiText("Unavailable", "利用不可")}`}</option>}
        {models.map((entry) => <option key={entry.id} value={entry.id}>{entry.display_name}</option>)}
      </Select></label>
      <label className="grid gap-1.5 text-xs font-medium text-muted-foreground">{transcription ? uiText("Transcription reasoning effort", "文字起こしの推論強度") : uiText("Reasoning effort", "推論強度")}<Select value={effortValue === undefined ? "__default" : effortValue}
        onValueChange={(value) => { setEffort(value === "__default" ? undefined : value); clearPendingRequest(); }}>
        <option value="__default" disabled={value !== undefined}>{defaultEffort ? defaultLabel(defaultEffort) : automaticDefaultLabel}</option>
        <option value="">{uiText("Automatic", "自動")}</option>
        {effortValue && !efforts.includes(effortValue) && <option value={effortValue} disabled>{effortValue} — {uiText("Check model compatibility", "モデルとの対応を確認")}</option>}
        {efforts.map((effort) => <option key={effort}>{effort}</option>)}
      </Select></label>
      </div>
      {!transcription && <label className="grid gap-1.5 text-xs font-medium text-muted-foreground">{uiText("Summary detail", "要約の詳細度")}<Select value={detail}
        onValueChange={(value) => { setDetail(value); clearPendingRequest(); }}>
        <option value="">{defaultLabel(defaultDetail ? detailLabel(defaultDetail) : uiText("Loading…", "読み込み中…"))}</option>
        {details.map((detail) => <option key={detail} value={detail}>{detailLabel(detail)}</option>)}
      </Select></label>}
      </fieldset>)}
      {catalog.error && <p className="text-sm text-destructive" role="alert">{catalog.error.message}</p>}
      <Button variant="outline" size="sm" className="w-fit" disabled={!enabled || catalog.loading} onClick={catalog.reload}>{uiText("Reload models", "モデル一覧を再取得")}</Button>
    </fieldset>
    <DialogFooter>
    <Button disabled={starting || active || query.loading || workspaceQuery.loading || !selectedSourceAvailable || isModelUnavailable} onClick={() => void start()}>
      {starting ? uiText("Starting…", "開始中…") : buttonLabel}
    </Button>
    </DialogFooter>
    {active && <><span role="status">{stageLabel(job.stage)} — {uiText("You can close this window.", "画面を閉じても処理は続きます。")}</span>
      <Button variant="outline" size="sm" disabled={starting} onClick={() => void action("cancel")}>{uiText("Cancel", "キャンセル")}</Button></>}
    {(job?.status === "failed" || job?.status === "cancelled") && <Button variant="outline" size="sm" disabled={starting} onClick={() => void action("retry")}>
      {uiText("Retry with the same settings", "同じ設定で再試行")}</Button>}
    {job?.status === "cancelled" && <span role="status">{uiText("Cancelled", "キャンセル済み")}</span>}
    {job?.status === "failed" && <span role="alert">{stageLabel(job.stage)}: {failureMessage}
      {job.error && <> ({job.error})</>}</span>}
    {(error || query.error) && <span role="alert">{error ?? query.error?.message}</span>}
  </div>;
}

export function ServerSummaryGeneration({ meetingId, workspaceId, dialogId, hasSummary = false, showTrigger = true, open, onOpenChange, restoreFocus }: {
  meetingId: string;
  workspaceId: string;
  dialogId?: string;
  hasSummary?: boolean;
  showTrigger?: boolean;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  restoreFocus?: HTMLElement | null;
}) {
  const [localOpen, setLocalOpen] = useState(false);
  const dialogOpen = open ?? localOpen;
  const setDialogOpen = (value: boolean) => { setLocalOpen(value); onOpenChange?.(value); };
  const title = hasSummary ? uiText("Regenerate AI summary", "AI 要約を再生成") : uiText("Generate AI summary", "AI 要約を生成");
  return <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
    {showTrigger && <Tooltip label={title}><DialogTrigger asChild><Button type="button" variant="ghost" size="icon" aria-label={title}><MenuIcon name="sparkles" /></Button></DialogTrigger></Tooltip>}
    <DialogContent id={dialogId} className="max-w-2xl gap-5" onCloseAutoFocus={(event) => {
      if (!restoreFocus?.isConnected) return;
      event.preventDefault();
      restoreFocus.focus({ preventScroll: true });
    }}>
      <DialogHeader className="pr-8">
        <DialogTitle className="flex items-center gap-2"><MenuIcon name="sparkles" />{uiText("AI summary", "AI 要約")}</DialogTitle>
        <DialogDescription>{uiText("Generate a summary on the server. These settings apply to this Web operation and do not change Desktop settings.", "サーバーで要約を生成します。ここで選ぶ設定はこのWeb操作に適用され、デスクトップの設定は変更しません。")}</DialogDescription>
      </DialogHeader>
      <SummaryGenerationSurface meetingId={meetingId} workspaceId={workspaceId} hasSummary={hasSummary} />
    </DialogContent>
  </Dialog>;
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

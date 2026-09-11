import { apiOperations as api } from "./generated-operations";
import type { components, operations } from "./generated-api";
import { apiQuery } from "./live-data";
import { Select } from "./Select";
import { MenuIcon } from "./Sidebar";
import { useEffect, useRef, useState } from "react";
import { json, RequestError, uiText } from "./api";
import { refreshData, useLiveJSON } from "./live-data";
import { encodeId } from "../typeid";
import { uuidV7 } from "../id";
import type { GatewayModelList } from "../ai-gateway/backend";
import { DEFAULT_ACCOUNT_SETTINGS, summaryStyles, summaryStyleDetail, type AccountSettings, type AccountSettingsPatch } from "../account-settings-model";
type SummaryRequest = operations["startSummaryJob"]["requestBody"]["content"]["application/json"];
import { isAudioSummaryModel, isSummaryModel } from "../summary/audio-model";
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

export function shouldResetManualSummaryModel(savedModel: string, models: GatewayModelList, source: SummarySource) {
  const model = models.data.find(({ id }) => id === savedModel || savedModel.endsWith(`.${id}`));
  return model && models.models.some(({ slug }) => slug === model.id) ? !isSummaryModel(model.id, models, source) : false;
}

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
const detailLabel = (detail: typeof details[number]) => ({ low: uiText("Concise", "簡潔"), medium: uiText("Standard", "標準"),
  high: uiText("Detailed", "詳細"), xhigh: uiText("Event session", "イベントセッション"), max: uiText("Event Play-by-Play", "イベント実況中継") })[detail];
const styleDescription = (style: AccountSettings["summary"]["style"]) => ({
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

export function ServerSummarySettings() {
  const capabilities = useSummaryMethods();
  const remoteSupported = capabilities.methods.includes("audio");
  const query = useLiveJSON<{ settings: AccountSettings | null }>(apiQuery("getSettings", {}), "account");
  const [error, setError] = useState<string>();
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const catalog = useLiveJSON<GatewayModelList>(remoteSupported ? "/api/v1/models" : undefined, "manual");
  const settings = query.data?.settings;
  const editingDisabled = saving || query.loading || !!query.error;

  const save = async (patch: AccountSettingsPatch) => {
    setSaving(true); setSaved(false); setError(undefined);
    try {
      const result = await api.updateSettings({ body: patch }, false);
      query.replace(result); query.reload(); setSaved(true);
    }
    catch (error) { setError(error instanceof Error ? error.message : uiText("Could not save settings", "設定を保存できません")); }
    finally { setSaving(false); }
  };
  const summary = settings?.summary ?? DEFAULT_ACCOUNT_SETTINGS.summary;
  const processing = settings?.processing ?? DEFAULT_ACCOUNT_SETTINGS.processing;
  const remote = processing.remote;
  const transcribesFirst = remote.workflow === "transcribeThenSummarize";
  const saveRemote = (value: NonNullable<NonNullable<AccountSettingsPatch["processing"]>["remote"]>) =>
    save({ processing: { remote: value } });
  const models = catalog.data?.data.filter((model) => model.id !== CODEX_AUTO_REVIEW_ALIAS
    && isSummaryModel(model.id, catalog.data!, transcribesFirst ? "transcript" : "audio")) ?? [];
  const audioModels = catalog.data?.data.filter((model) => isAudioSummaryModel(model.id, catalog.data!)) ?? [];
  const selectedTranscriptionModel = audioModels.find((model) => model.id === remote.transcriptionModel
    || remote.transcriptionModel?.endsWith(`.${model.id}`));
  const selectedSummaryModel = models.find((model) => model.id === remote.summaryModel || remote.summaryModel?.endsWith(`.${model.id}`));
  const metadata = catalog.data?.models.find((model) => model.slug === selectedSummaryModel?.id);
  const efforts = metadata?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
  if (!query.data) return <section className="section-block settings-section" aria-busy={query.loading}>
    {query.error ? <p className="error" role="alert">{uiText("Could not load account settings. Your saved preferences have not changed.", "アカウント設定を読み込めませんでした。保存済みの設定は変更されていません。")}
      <button className="secondary" onClick={query.reload}>{uiText("Retry", "再試行")}</button></p>
      : <p role="status">{uiText("Loading settings…", "設定を読み込み中…")}</p>}
  </section>;
  return <>
    <p className="settings-save-status" role="status" data-saved={saved && !saving}>{saving ? uiText("Saving changes…", "変更を保存中…") : saved ? uiText("Changes saved", "変更を保存しました") : uiText("Changes save automatically and apply to your next summary.", "変更は自動で保存され、次回の要約から適用されます。")}</p>
    {(error || query.error) && <p role="alert" className="error">{error ?? query.error?.message} {query.error && <button className="secondary" onClick={query.reload}>{uiText("Retry", "再試行")}</button>}</p>}
    <section className="section-block settings-section">
      <h2 className="section-label">{uiText("Results", "生成結果")}</h2>
      <fieldset className="account-settings" disabled={editingDisabled}>
        <label>{uiText("Summary style", "まとめ方")}<Select value={summary.style}
          onValueChange={(value) => void save({ summary: { style: value as AccountSettings["summary"]["style"] } })}>
          {summaryStyles.map((style) => <option key={style} value={style}>{detailLabel(summaryStyleDetail(style))}</option>)}
        </Select></label>
        <p>{styleDescription(summary.style)}</p>
        <label>{uiText("Output language", "出力言語")}<Select value={settings?.outputLanguage ?? DEFAULT_ACCOUNT_SETTINGS.outputLanguage}
          onValueChange={(value) => void save({ outputLanguage: value as AccountSettings["outputLanguage"] })}>
          {Object.entries({ ja: "日本語", en: "English", zh: "中文", ko: "한국어", fr: "Français", de: "Deutsch", es: "Español" }).map(([id, name]) => <option key={id} value={id}>{name}</option>)}
        </Select></label>
        <p>{uiText("Shared by summaries and image analysis. Speech recognition languages are unchanged.", "出力言語は要約と画像の説明に共通です。音声認識の言語は変更しません。")}</p>
      </fieldset>
    </section>
    <section className="section-block settings-section">
      <h2 className="section-label">{uiText("Transcription and summary", "文字起こしと要約")}</h2>
      <fieldset className="account-settings" disabled={editingDisabled}>
        <label>{uiText("Processing location", "処理する場所")}<Select value={processing.location}
          onValueChange={(value) => void save({ processing: { location: value as AccountSettings["processing"]["location"] } })}>
          <option value="local">{uiText("Dahlia for Mac", "Dahlia for Mac")}</option>
          {(remoteSupported || processing.location === "remote") && <option value="remote" disabled={!remoteSupported}>
            {uiText("Server", "サーバー")}</option>}
        </Select></label>
        {processing.location === "local" && <p>{uiText("Dahlia for Mac transcribes locally and sends transcripts and images to the AI provider configured on that Mac. Generation is unavailable on the web.", "Dahlia for Macで文字起こしし、そのMacに設定したAI接続先へ文字起こしや画像を送って要約します。Webからは生成できません。")}</p>}
        {processing.location === "remote" && <p>{uiText(
          "New recordings use the selected automatic server processing. Manual generation uses the source selected on the meeting screen.",
          "新しい録音には選択したサーバーの自動処理を使います。手動生成ではミーティング画面のソース選択が優先されます。",
        )}</p>}
        {capabilities.loading && <p role="status">{uiText("Checking server capabilities…", "サーバー機能を確認中…")}</p>}
        {processing.location === "remote" && !remoteSupported && !capabilities.loading && <p>{uiText("Remote processing is unavailable on this server.", "このサーバーではリモート処理を利用できません。")}</p>}
        {capabilities.error && <p role="alert" className="error">{capabilities.error.message} <button className="secondary"
          onClick={capabilities.reload}>{uiText("Retry", "再試行")}</button></p>}
        {processing.location === "remote" && catalog.data && ((remote.summaryModel && !selectedSummaryModel)
          || (transcribesFirst && remote.transcriptionModel && !selectedTranscriptionModel)) && <p role="status">{uiText(
          "A selected model is unavailable. Open advanced settings to change it or choose Automatic.",
          "利用できないモデルが指定されています。詳細設定で変更するか「自動」に戻してください。",
        )}</p>}
        {processing.location === "remote" && remoteSupported && <details className="settings-advanced">
          <summary>{uiText("Advanced server settings", "サーバー処理の詳細設定")}</summary>
          <p>{uiText(
            "These choices apply automatically after new recordings. Manual generation uses the source selected on the meeting screen.",
            "ここでの選択は、新しい録音後の自動処理に適用されます。手動生成では、ミーティング画面で選んだソースが優先されます。",
          )}</p>
          <label>{uiText("New recording automatic processing", "新しい録音の自動処理")}<Select value={remote.workflow}
            onValueChange={(value) => void saveRemote({ workflow: value as typeof remote.workflow })}>
            <option value="transcribeThenSummarize">{uiText("Transcribe, then summarize", "文字起こししてから要約")}</option>
            <option value="combined">{uiText("Generate together", "文字起こしと要約を一括生成")}</option>
          </Select></label>
          <label>{uiText("Summary model", "要約モデル")}<Select value={selectedSummaryModel?.id ?? remote.summaryModel ?? ""} disabled={catalog.loading}
            onValueChange={(value) => void saveRemote({ summaryModel: value || null })}>
            <option value="">{uiText("Automatic", "自動")}</option>
            {remote.summaryModel && !selectedSummaryModel && <option value={remote.summaryModel} disabled>{remote.summaryModel} — {uiText("Unavailable for this workflow", "この方式では利用不可")}</option>}
            {models.map((model) => <option key={model.id} value={model.id}>{model.display_name}</option>)}
          </Select></label>
          <label>{uiText("Reasoning effort", "推論強度")}<Select value={remote.reasoningEffort ?? ""}
            onValueChange={(value) => void saveRemote({ reasoningEffort: value ? value as typeof remote.reasoningEffort : null })}>
            <option value="">{uiText("Automatic", "自動")}</option>
            {remote.reasoningEffort && !efforts.includes(remote.reasoningEffort) && <option value={remote.reasoningEffort} disabled>{remote.reasoningEffort} — {uiText("Check model compatibility", "モデルとの対応を確認")}</option>}
            {efforts.map((effort) => <option key={effort}>{effort}</option>)}
          </Select></label>
          {transcribesFirst && <label>{uiText("Transcription model", "文字起こしモデル")}<Select
            value={selectedTranscriptionModel?.id ?? remote.transcriptionModel ?? ""} onValueChange={(value) => void saveRemote({ transcriptionModel: value || null })}>
            <option value="">{uiText("Automatic", "自動")}</option>
            {remote.transcriptionModel && !selectedTranscriptionModel && <option value={remote.transcriptionModel} disabled>{remote.transcriptionModel} — {uiText("Unavailable", "利用不可")}</option>}
            {audioModels.map((entry) => <option key={entry.id} value={entry.id}>{entry.display_name}</option>)}
          </Select></label>}
          {catalog.error && <p role="alert" className="error">{catalog.error.message}</p>}
          {!catalog.loading && !models.length && <p>{uiText("No models available", "利用可能なモデルがありません")}</p>}
          <button className="secondary" onClick={catalog.reload} disabled={catalog.loading}>{uiText("Reload models", "モデル一覧を再取得")}</button>
        </details>}
      </fieldset>
    </section>
  </>;
}

export function ServerSummaryGeneration({ meetingId }: { meetingId: string }) {
  const methods = useSummaryMethods().manualMethods;
  const enabled = methods.length > 0;
  const query = useLiveJSON<{ job: Job }>(enabled ? apiQuery("getLatestSummaryJob", { params: { path: { meetingId } } }) : undefined);
  const accountQuery = useLiveJSON<{ settings: AccountSettings | null }>(apiQuery("getSettings", {}), "account");
  const transcriptQuery = useLiveJSON<TranscriptSnapshot>(methods.includes("transcript") ? {
    key: JSON.stringify(["summaryTranscriptAvailability", { meetingId }]),
    load: (signal) => loadTranscript(meetingId, signal),
  } : undefined);
  const recordingsQuery = useLiveJSON<RecordingSnapshot>(methods.includes("audio") ? {
    key: JSON.stringify(["summaryRecordingAvailability", { meetingId }]),
    load: (signal) => loadRecordings(meetingId, signal),
  } : undefined);
  const catalog = useLiveJSON<GatewayModelList>(enabled ? "/api/v1/models" : undefined, "manual");
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string>();
  const [detail, setDetail] = useState("");
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
  if (!enabled) return null;
  const remoteEnabled = accountQuery.data?.settings?.processing.location === "remote";
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
        const account = await api.getSettings({});
        const settings = account.settings ?? DEFAULT_ACCOUNT_SETTINGS;
        if (settings.processing.location !== "remote") throw new Error(uiText(
          "This account processes summaries in Dahlia for Mac.",
          "このアカウントはDahlia for Macで要約を処理します。",
        ));
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
        if (remote.summaryModel) {
          const models = catalog.data ?? await json<GatewayModelList>("/api/v1/models", undefined, { notifyMutation: false });
          if (shouldResetManualSummaryModel(remote.summaryModel, models, selectedSource)) {
            delete remote.summaryModel;
            delete remote.reasoningEffort;
          }
        }
        requestBody.current = { id: requestID.current, input,
          preferences: { processing: { location: "remote", remote }, outputLanguage: settings.outputLanguage,
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

  return <div className="summary-generation">
    <div className="generation-copy"><strong><MenuIcon name="sparkles" />{uiText("AI summary", "AI 要約")}</strong><span>{uiText("Turn this conversation into clear next steps.", "会話のポイントと、次のアクションを整理します。")}</span></div>
    <fieldset className="summary-source-options" disabled={active || starting} aria-busy={transcriptQuery.loading || recordingsQuery.loading}>
      <legend>{uiText("Source for this generation", "今回の生成ソース")}</legend>
      <div>
        {(["transcript", "audio"] as const).map((candidate) => {
          const available = sourceAvailable(candidate);
          const reason = sourceReason(candidate);
          return <label key={candidate} data-disabled={!available}>
            <input type="radio" name={`summary-source-${meetingId}`} value={candidate} checked={selectedSource === candidate}
              disabled={!available} onChange={() => { setSource(candidate); clearPendingRequest(); }} />
            <span><strong>{candidate === "transcript" ? uiText("Transcript", "文字起こし") : uiText("Recording audio", "録音音声")}</strong>
              <small>{candidate === "transcript"
                ? uiText("Regenerate only the summary from the latest transcript.", "最新の文字起こしから要約だけを再生成します。")
                : uiText("Regenerate both the transcript and summary from all recordings.", "すべての録音から文字起こしと要約を再生成します。")}</small>
              {reason && <small>{reason}</small>}
            </span>
          </label>;
        })}
      </div>
    </fieldset>
    <div className="generation-controls">
    <Select aria-label={uiText("Summary detail", "要約の詳細度")} value={detail} disabled={active || starting}
      onValueChange={(value) => { setDetail(value); clearPendingRequest(); }}>
      <option value="">{uiText("Account default", "アカウント設定")}</option>
      {details.map((detail) => <option key={detail} value={detail}>{detailLabel(detail)}</option>)}
    </Select>
    <button className="primary" disabled={starting || active || query.loading || accountQuery.loading || !remoteEnabled || !selectedSourceAvailable} onClick={() => void start()}>
      {starting ? uiText("Starting…", "開始中…") : buttonLabel}
    </button>
    </div>
    {!accountQuery.loading && !remoteEnabled && <span>{uiText(
      "This account processes summaries in Dahlia for Mac.",
      "このアカウントはDahlia for Macで要約を処理します。",
    )}</span>}
    {active && <><span role="status">{stageLabel(job.stage)} — {uiText("You can close this window.", "画面を閉じても処理は続きます。")}</span>
      <button disabled={starting} onClick={() => void action("cancel")}>{uiText("Cancel", "キャンセル")}</button></>}
    {(job?.status === "failed" || job?.status === "cancelled") && <button disabled={starting} onClick={() => void action("retry")}>
      {uiText("Retry with the same settings", "同じ設定で再試行")}</button>}
    {job?.status === "cancelled" && <span role="status">{uiText("Cancelled", "キャンセル済み")}</span>}
    {job?.status === "failed" && <span role="alert">{stageLabel(job.stage)}: {failureMessage}
      {job.error && <> ({job.error})</>}</span>}
    {(error || query.error) && <span role="alert">{error ?? query.error?.message}</span>}
  </div>;
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

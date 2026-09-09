import { apiOperations as api } from "./generated-operations";
import type { components, operations } from "./generated-api";
import { apiQuery } from "./live-data";
import { Select } from "./Select";
import { MenuIcon } from "./Sidebar";
import { useEffect, useRef, useState } from "react";
import { RequestError, uiText } from "./api";
import { refreshData, useLiveJSON } from "./live-data";
import { encodeId } from "../typeid";
import { uuidV7 } from "../id";
import type { GatewayModelList } from "../ai-gateway/backend";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettings, type AccountSettingsPatch } from "../account-settings-model";
type SummaryRequest = operations["startSummaryJob"]["requestBody"]["content"]["application/json"];
import { isAudioSummaryModel, isSummaryModel } from "../summary/audio-model";
import { CODEX_AUTO_REVIEW_ALIAS } from "../ai-gateway/model-alias";

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

function useSummaryMethods() {
  const capabilities = useLiveJSON<{ meetingSummaryGeneration?: { version: number; sources: string[] } }>(apiQuery("getCapabilities", {}));
  const summary = capabilities.data?.meetingSummaryGeneration;
  return { ...capabilities, methods: summary?.version === 2 ? summary.sources : [] };
}

export function ServerSummarySettings() {
  const capabilities = useSummaryMethods();
  const methods = capabilities.methods;
  const remoteSupported = methods.includes("audio");
  const query = useLiveJSON<{ settings: AccountSettings | null }>(apiQuery("getSettings", {}), "account");
  const [error, setError] = useState<string>();
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const catalog = useLiveJSON<GatewayModelList>(remoteSupported ? "/api/v1/models" : undefined, "manual");
  const settings = query.data?.settings;

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
  const remote = summary.remote;
  const transcribesFirst = remote.transcriptionModel !== undefined;
  const saveRemote = (value: Omit<Partial<AccountSettings["summary"]["remote"]>, "transcriptionModel"> & { transcriptionModel?: string | null }) =>
    save({ summary: { remote: value } });
  const modelsFor = (transcription: boolean) => catalog.data?.data.filter((model) => model.id !== CODEX_AUTO_REVIEW_ALIAS
    && isSummaryModel(model.id, catalog.data!, transcription ? "transcript" : "audio")) ?? [];
  const models = modelsFor(transcribesFirst);
  const audioModels = catalog.data?.data.filter((model) => isAudioSummaryModel(model.id, catalog.data!)) ?? [];
  const selectedTranscriptionModel = audioModels.find((model) => model.id === remote.transcriptionModel
    || remote.transcriptionModel?.endsWith(`.${model.id}`));
  const selected = models.find((model) => model.id === remote.model || remote.model.endsWith(`.${model.id}`));
  const metadata = catalog.data?.models.find((model) => model.slug === selected?.id);
  const efforts = metadata?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
  const reasoningEffortFor = (modelID: string) => {
    const model = catalog.data?.models.find((model) => model.slug === modelID);
    const supported = model?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
    if (supported.includes(remote.reasoningEffort)) return remote.reasoningEffort;
    return (model?.default_reasoning_level ?? supported[0] ?? "none") as typeof remote.reasoningEffort;
  };
  const setTranscribesFirst = (enabled: boolean) => {
    const transcriptionModel = enabled ? audioModels[0]?.id : null;
    if (transcriptionModel === undefined) return;
    const nextModels = modelsFor(enabled);
    const next = nextModels.find((model) => model.id === remote.model || remote.model.endsWith(`.${model.id}`)) ?? nextModels[0];
    if (!next) return;
    void saveRemote({ transcriptionModel, model: next.id, reasoningEffort: reasoningEffortFor(next.id) });
  };
  return <>
    <p className="settings-save-status" role="status" data-saved={saved && !saving}>{saving ? uiText("Saving changes…", "変更を保存中…") : saved ? uiText("Changes saved", "変更を保存しました") : uiText("Changes save automatically and apply to your next summary.", "変更は自動で保存され、次回の要約から適用されます。")}</p>
    <section className="section-block settings-section">
      <h2 className="section-label">{uiText("Output language", "出力言語")}</h2>
      <p>{uiText("Shared by summaries and image analysis.", "要約と画像解析に共通で使用します。")}</p>
      <fieldset className="account-settings" disabled={saving || query.loading}>
        <label>{uiText("Output language", "出力言語")}<Select value={settings?.outputLanguage ?? DEFAULT_ACCOUNT_SETTINGS.outputLanguage}
          onValueChange={(value) => void save({ outputLanguage: value as AccountSettings["outputLanguage"] })}>
          {Object.entries({ ja: "日本語", en: "English", zh: "中文", ko: "한국어", fr: "Français", de: "Deutsch", es: "Español" }).map(([id, name]) => <option key={id} value={id}>{name}</option>)}
        </Select></label>
      </fieldset>
    </section>
    <section className="section-block settings-section">
    <h2 className="section-label">{uiText("Transcription and summary", "文字起こしと要約")}</h2>
    <p>{uiText("This setting is shared by every device signed in to this Dahlia account.", "この設定はDahliaアカウントにサインインしているすべての端末で共有されます。")}</p>
    <fieldset className="account-settings" disabled={saving || query.loading}>
      <label>{uiText("Processing location", "処理する場所")}<Select value={summary.mode}
        onValueChange={(value) => void save({ summary: { mode: value as AccountSettings["summary"]["mode"] } })}>
        <option value="local">{uiText("Local (Dahlia for Mac)", "ローカル（Dahlia for Mac）")}</option>
        {(remoteSupported || summary.mode === "remote") && <option value="remote" disabled={!remoteSupported}>
          {uiText("Remote (server)", "リモート（サーバー）")}</option>}
      </Select></label>
      {summary.mode === "local" && <p>{uiText("Dahlia for Mac creates the transcript and summary. Generation is unavailable on the web.", "Dahlia for Macで文字起こしと要約を作成します。Webからは生成できません。")}</p>}
      {capabilities.loading && <p role="status">{uiText("Checking server capabilities…", "サーバー機能を確認中…")}</p>}
      {summary.mode === "remote" && !remoteSupported && !capabilities.loading && <p>{uiText("Remote processing is unavailable on this server.", "このサーバーではリモート処理を利用できません。")}</p>}
      {capabilities.error && <p role="alert" className="error">{capabilities.error.message} <button className="secondary"
        onClick={capabilities.reload}>{uiText("Retry", "再試行")}</button></p>}
      {summary.mode === "remote" && remoteSupported && <>
      <label><input type="checkbox" checked={transcribesFirst}
        disabled={catalog.loading || !audioModels.length} onChange={(event) => setTranscribesFirst(event.target.checked)} />
        {uiText("Transcribe before generating the summary", "先に文字起こしする")}</label>
      <label>{uiText("Detail", "詳細度")}<Select value={remote.detail}
        onValueChange={(value) => void saveRemote({ detail: value as AccountSettings["summary"]["remote"]["detail"] })}>
        {details.map((detail) => <option key={detail} value={detail}>{detailLabel(detail)}</option>)}
      </Select></label>
      <label>{uiText("Model", "モデル")}<Select value={selected?.id ?? ""} disabled={catalog.loading || !models.length}
        onValueChange={(value) => void saveRemote({ model: value, reasoningEffort: reasoningEffortFor(value) })}>
        {!selected && <option value="" disabled>{uiText("Select an available model", "利用可能なモデルを選択")}</option>}
        {models.map((model) => <option key={model.id} value={model.id}>{model.display_name}</option>)}
      </Select></label>
      {catalog.error && <p role="alert" className="error">{catalog.error.message}</p>}
      {!catalog.loading && !models.length && <p>{uiText("No models available", "利用可能なモデルがありません")}</p>}
      <button className="secondary" onClick={catalog.reload} disabled={catalog.loading}>{uiText("Reload models", "モデル一覧を再取得")}</button>
      <label>{uiText("Reasoning effort", "推論強度")}<Select value={efforts.includes(remote.reasoningEffort) ? remote.reasoningEffort : ""} disabled={!efforts.length}
        onValueChange={(value) => void saveRemote({ reasoningEffort: value as typeof remote.reasoningEffort })}>
        {!efforts.includes(remote.reasoningEffort) && <option value="" disabled>{uiText("Select reasoning effort", "推論強度を選択")}</option>}
        {efforts.map((effort) => <option key={effort}>{effort}</option>)}
      </Select></label>
      {transcribesFirst && <label>{uiText("Transcription model", "文字起こしモデル")}<Select
        value={selectedTranscriptionModel?.id ?? ""} onValueChange={(value) => void saveRemote({ transcriptionModel: value })}>
        {!selectedTranscriptionModel && <option value="" disabled>{uiText("Select an available model", "利用可能なモデルを選択")}</option>}
        {audioModels.map((entry) => <option key={entry.id} value={entry.id}>{entry.display_name}</option>)}
      </Select></label>}
      </>}
    </fieldset>
    </section>
    {(error || query.error) && <p role="alert" className="error">{error ?? query.error?.message} {query.error && <button className="secondary" onClick={query.reload}>{uiText("Retry", "再試行")}</button>}</p>}
  </>;
}

export function ServerSummaryGeneration({ meetingId }: { meetingId: string }) {
  const methods = useSummaryMethods().methods;
  const enabled = methods.length > 0;
  const remoteSupported = methods.includes("audio");
  const query = useLiveJSON<{ job: Job }>(enabled ? apiQuery("getLatestSummaryJob", { params: { path: { meetingId } } }) : undefined);
  const accountQuery = useLiveJSON<{ settings: AccountSettings | null }>(apiQuery("getSettings", {}), "account");
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string>();
  const [detail, setDetail] = useState("");
  const completed = useRef<string | undefined>(undefined);
  const requestID = useRef<string | undefined>(undefined);
  const requestBody = useRef<SummaryRequest | undefined>(undefined);
  const job = query.data?.job;
  useEffect(() => {
    if (!enabled) return;
    const timer = window.setInterval(query.reload, 5000);
    return () => window.clearInterval(timer);
  }, [enabled, meetingId]); // reload uses the query's current queue.
  useEffect(() => {
    if (job?.id === requestID.current) { requestID.current = undefined; requestBody.current = undefined; }
    if (job?.status === "succeeded" && completed.current !== job.id) {
      completed.current = job.id; refreshData();
    }
  }, [job?.id, job?.status]);
  if (!enabled) return null;
  const remoteEnabled = remoteSupported && accountQuery.data?.settings?.summary.mode === "remote";
  const active = job?.status === "pending" || job?.status === "processing";
  const start = async () => {
    setStarting(true); setError(undefined);
    requestID.current ??= encodeId("summaryJob", uuidV7());
    try {
      if (!requestBody.current) {
        const account = await api.getSettings({});
        const settings = account.settings ?? DEFAULT_ACCOUNT_SETTINGS;
        if (settings.summary.mode !== "remote") throw new Error(uiText(
          "This account processes summaries in Dahlia for Mac.",
          "このアカウントはDahlia for Macで要約を処理します。",
        ));
        const recordings: { micFileId: string | null; systemFileId: string | null }[] = [];
        let cursor: string | null = null;
        do {
          const page: { items: { audio: Partial<Record<"mic" | "system", { fileId?: string }>> }[]; nextCursor: string | null } =
            await api.listRecordings({ params: { path: { meetingId }, query: { cursor: cursor ?? undefined } } });
          recordings.push(...page.items.map(({ audio }) => ({ micFileId: audio.mic?.fileId ?? null, systemFileId: audio.system?.fileId ?? null })));
          cursor = page.nextCursor;
        } while (cursor !== null);
        const input: Extract<SummaryRequest, { input: unknown }>["input"] = { type: "recording", recordings,
          ...(settings.summary.remote.transcriptionModel ? { transcriptionModel: settings.summary.remote.transcriptionModel } : {}) };
        requestBody.current = { id: requestID.current, input,
          model: settings.summary.remote.model,
          detail: (detail || settings.summary.remote.detail) as typeof details[number], outputLanguage: settings.outputLanguage,
          reasoningEffort: settings.summary.remote.reasoningEffort };
      }
      await api.startSummaryJob({ params: { path: { meetingId } }, body: requestBody.current });
      requestID.current = undefined; requestBody.current = undefined; query.reload();
    } catch (error) {
      if (error instanceof RequestError && error.status === 400) {
        requestID.current = undefined; requestBody.current = undefined;
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
      requestID.current = undefined; requestBody.current = undefined; query.reload();
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
    <div className="generation-controls">
    <Select aria-label={uiText("Summary detail", "要約の詳細度")} value={detail} disabled={active || starting}
      onValueChange={(value) => { setDetail(value); requestID.current = undefined; requestBody.current = undefined; }}>
      <option value="">{uiText("Account default", "アカウント設定")}</option>
      {details.map((detail) => <option key={detail} value={detail}>{detailLabel(detail)}</option>)}
    </Select>
    <button className="primary" disabled={starting || active || query.loading || accountQuery.loading || !remoteEnabled} onClick={() => void start()}>
      {starting ? uiText("Starting…", "開始中…") : buttonLabel}
    </button>
    </div>
    {!accountQuery.loading && !remoteEnabled && <span>{uiText(
      remoteSupported ? "This account processes summaries in Dahlia for Mac." : "Remote summary generation is unavailable on this server.",
      remoteSupported ? "このアカウントはDahlia for Macで要約を処理します。" : "このサーバーではリモート要約生成を利用できません。",
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

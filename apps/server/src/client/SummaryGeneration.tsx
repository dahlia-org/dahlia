import { useEffect, useRef, useState } from "react";
import { json, uiText } from "./api";
import { refreshData, useLiveJSON } from "./live-data";
import { uuidV7 } from "../id";
import type { GatewayModelList } from "../ai-gateway/backend";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettings, type AccountSettingsPatch } from "../account-settings-model";
import type { summaryJobResponse } from "../summary/service";
import { isAudioSummaryModel } from "../summary/audio-model";
import { CODEX_AUTO_REVIEW_ALIAS } from "../ai-gateway/model-alias";

const summaryErrors: Record<string, string> = {
  summary_audio_empty: uiText("No committed audio is available. Finish uploading recordings first.", "確定済みの音声がありません。録音のアップロード完了後に再試行してください。"),
  summary_audio_too_long: uiText("Combined mic/system audio exceeds 9.5 hours.", "マイク・システム音声の合計が9.5時間を超えています。"),
  summary_audio_request_too_large: uiText("The provider rejected the request size. No audio was truncated.", "モデルの送信サイズ上限を超えました。音声は切り捨てていません。"),
  summary_audio_changed: uiText("Recording bytes changed. Retry after uploads finish.", "録音データが変化しました。アップロード完了後に再試行してください。"),
  summary_audio_unavailable: uiText("Recording audio could not be read.", "録音音声を読み取れませんでした。"),
  summary_invalid_audio_model: uiText("Select an available audio-capable Gemini model in settings.", "設定で利用可能な音声対応Geminiモデルを選択してください。"),
};
type Job = ReturnType<typeof summaryJobResponse>;
const details = ["concise", "standard", "detailed", "eventSession"] as const;
const detailLabel = (detail: typeof details[number]) => ({ concise: uiText("Concise", "簡潔"), standard: uiText("Standard", "標準"),
  detailed: uiText("Detailed", "詳細"), eventSession: uiText("Event session", "イベントセッション") })[detail];

function useSummaryMethods() {
  const capabilities = useLiveJSON<{ meetingSummaryGeneration?: { version: number; sources: string[] } }>("/api/v1/capabilities");
  const summary = capabilities.data?.meetingSummaryGeneration;
  return summary?.version === 1 ? summary.sources : [];
}

export function ServerSummarySettings() {
  const methods = useSummaryMethods();
  const query = useLiveJSON<{ settings: AccountSettings | null }>("/api/v1/account/settings", "account");
  const [error, setError] = useState<string>();
  const [saving, setSaving] = useState(false);
  const catalog = useLiveJSON<GatewayModelList>(methods.length ? "/api/v1/models" : undefined, "manual");
  const settings = query.data?.settings;

  const save = async (patch: AccountSettingsPatch) => {
    setSaving(true); setError(undefined);
    try {
      const result = await json<{ settings: AccountSettings }>("/api/v1/account/settings",
        { method: "PATCH", body: JSON.stringify(patch) }, { notifyMutation: false });
      query.replace(result); query.reload();
    }
    catch (error) { setError(error instanceof Error ? error.message : uiText("Could not save settings", "設定を保存できません")); }
    finally { setSaving(false); }
  };
  const method = settings?.summary.method ?? "transcript";
  const saveSource = (value: Partial<AccountSettings["summary"]["methodSettings"]["transcript"]>) =>
    save({ summary: { methodSettings: { [method]: value } } });
  const source = settings?.summary.methodSettings[method] ?? DEFAULT_ACCOUNT_SETTINGS.summary.methodSettings[method];
  const models = catalog.data?.data.filter((model) => model.id !== CODEX_AUTO_REVIEW_ALIAS
    && (method !== "audio" || isAudioSummaryModel(model.id, catalog.data!))) ?? [];
  const selected = models.find((model) => model.id === source.model || source.model.endsWith(`.${model.id}`));
  const metadata = catalog.data?.models.find((model) => model.slug === selected?.id);
  const efforts = metadata?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
  return <>
    <section className="section-block">
      <h2 className="section-label">{uiText("Output language", "出力言語")}</h2>
      <p>{uiText("Shared by summaries and image analysis.", "要約と画像解析に共通で使用します。")}</p>
      <fieldset className="account-settings" disabled={saving || query.loading}>
        <label>{uiText("Output language", "出力言語")}<select value={settings?.outputLanguage ?? DEFAULT_ACCOUNT_SETTINGS.outputLanguage}
          onChange={(event) => void save({ outputLanguage: event.target.value as AccountSettings["outputLanguage"] })}>
          {Object.entries({ ja: "日本語", en: "English", zh: "中文", ko: "한국어", fr: "Français", de: "Deutsch", es: "Español" }).map(([id, name]) => <option key={id} value={id}>{name}</option>)}
        </select></label>
      </fieldset>
    </section>
    {methods.length > 0 && <section className="section-block">
    <h2 className="section-label">{uiText("Server summary", "サーバー要約")}</h2>
    <p>{uiText("Settings apply to new jobs. Export summaries separately after generation.", "設定は次回の生成から適用されます。エクスポートは生成後に個別に行います。")}</p>
    {method === "audio" && <p>{uiText("Uses uploaded recordings and images. The combined mic/system audio limit is 9.5 hours. Oversized requests fail without truncation.", "アップロード済みの音声と画像を使用します。マイク・システム音声の合計上限は9.5時間です。送信上限を超える場合は切り捨てずに停止します。")}</p>}
    <fieldset className="account-settings" disabled={saving || query.loading}>
      <label>{uiText("Summary source", "要約のソース")}<select value={method}
        onChange={(event) => void save({ summary: { method: event.target.value as typeof method } })}>
        {methods.map((method) => <option key={method} value={method}>{method === "audio" ? uiText("Audio and images", "音声と画像") : uiText("Transcript and images", "文字起こしと画像")}</option>)}
      </select></label>
      <label>{uiText("Detail", "詳細度")}<select value={settings?.summary.detail ?? DEFAULT_ACCOUNT_SETTINGS.summary.detail}
        onChange={(event) => void save({ summary: { detail: event.target.value as AccountSettings["summary"]["detail"] } })}>
        {details.map((detail) => <option key={detail} value={detail}>{detailLabel(detail)}</option>)}
      </select></label>
      <label>{uiText("Model", "モデル")}<select value={selected?.id ?? ""} disabled={catalog.loading || !models.length}
        onChange={(event) => {
          const model = catalog.data?.models.find((model) => model.slug === event.target.value);
          const supported = model?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
          void saveSource({ model: event.target.value,
            reasoningEffort: (supported.includes(source.reasoningEffort) ? source.reasoningEffort
              : model?.default_reasoning_level ?? supported[0] ?? "none") as typeof source.reasoningEffort });
        }}>
        {!selected && <option value="" disabled>{uiText("Select an available model", "利用可能なモデルを選択")}</option>}
        {models.map((model) => <option key={model.id} value={model.id}>{model.display_name}</option>)}
      </select></label>
      {catalog.error && <p role="alert" className="error">{catalog.error.message}</p>}
      {!catalog.loading && !models.length && <p>{uiText("No models available", "利用可能なモデルがありません")}</p>}
      <button onClick={catalog.reload} disabled={catalog.loading}>{uiText("Reload models", "モデル一覧を再取得")}</button>
      <label>{uiText("Reasoning effort", "推論強度")}<select value={efforts.includes(source.reasoningEffort) ? source.reasoningEffort : ""} disabled={!efforts.length}
        onChange={(event) => void saveSource({ reasoningEffort: event.target.value as typeof source.reasoningEffort })}>
        {!efforts.includes(source.reasoningEffort) && <option value="" disabled>{uiText("Select reasoning effort", "推論強度を選択")}</option>}
        {efforts.map((effort) => <option key={effort}>{effort}</option>)}
      </select></label>
    </fieldset>
    </section>}
    {(error || query.error) && <p role="alert" className="error">{error ?? query.error?.message}</p>}
  </>;
}

export function ServerSummaryGeneration({ base }: { base: string }) {
  const methods = useSummaryMethods();
  const enabled = methods.length > 0;
  const query = useLiveJSON<{ job: Job }>(enabled ? `${base}/summary/job` : undefined);
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string>();
  const [detail, setDetail] = useState("");
  const completed = useRef<string | undefined>(undefined);
  const requestID = useRef<string | undefined>(undefined);
  const job = query.data?.job;
  useEffect(() => {
    if (!enabled) return;
    const timer = window.setInterval(query.reload, 5000);
    return () => window.clearInterval(timer);
  }, [enabled, base]); // reload uses the query's current queue.
  useEffect(() => {
    if (job?.id === requestID.current) requestID.current = undefined;
    if (job?.status === "succeeded" && completed.current !== job.id) {
      completed.current = job.id; refreshData();
    }
  }, [job?.id, job?.status]);
  if (!enabled) return null;
  const active = job?.status === "pending" || job?.status === "processing";
  const start = async () => {
    setStarting(true); setError(undefined);
    requestID.current ??= uuidV7();
    try {
      await json(`${base}/summary`, { method: "POST", body: JSON.stringify({ id: requestID.current, ...(detail ? { detail } : {}) }) });
      requestID.current = undefined; query.reload();
    } catch (error) { setError(error instanceof Error ? summaryErrors[error.message] ?? error.message : uiText("Could not start summary", "要約を開始できません")); query.reload(); }
    finally { setStarting(false); }
  };
  let buttonLabel = uiText("Generate summary", "要約を生成");
  if (active) buttonLabel = uiText("Generating on server…", "サーバーで生成中…");
  else if (job?.status === "failed") buttonLabel = uiText("Retry summary", "要約を再試行");

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
    <select aria-label={uiText("Summary detail", "要約の詳細度")} value={detail} disabled={active || starting}
      onChange={(event) => { setDetail(event.target.value); requestID.current = undefined; }}>
      <option value="">{uiText("Account default", "アカウント設定")}</option>
      {details.map((detail) => <option key={detail} value={detail}>{detailLabel(detail)}</option>)}
    </select>
    <button disabled={starting || active || query.loading} onClick={() => void start()}>
      {buttonLabel}
    </button>
    {active && <span role="status">{uiText("You can close this window.", "画面を閉じても処理は続きます。")}</span>}
    {job?.status === "failed" && <span role="alert">{failureMessage}
      {job.error && <> ({job.error})</>}</span>}
    {(error || query.error) && <span role="alert">{error ?? query.error?.message}</span>}
  </div>;
}

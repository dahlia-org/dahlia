import { Select } from "./Select";
import { MenuIcon } from "./Sidebar";
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
  const [saved, setSaved] = useState(false);
  const catalog = useLiveJSON<GatewayModelList>(methods.length ? "/api/v1/models" : undefined, "manual");
  const settings = query.data?.settings;

  const save = async (patch: AccountSettingsPatch) => {
    setSaving(true); setSaved(false); setError(undefined);
    try {
      const result = await json<{ settings: AccountSettings }>("/api/v1/account/settings",
        { method: "PATCH", body: JSON.stringify(patch) }, { notifyMutation: false });
      query.replace(result); query.reload(); setSaved(true);
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
    {methods.length > 0 && <section className="section-block settings-section">
    <h2 className="section-label">{uiText("Server summary", "サーバー要約")}</h2>
    <p>{uiText("Choose the source and level of detail for your meeting summaries.", "ミーティングの要約に使用するソースと、内容の詳しさを設定します。")}</p>
    {method === "audio" && <p>{uiText("Uses uploaded recordings and images. The combined mic/system audio limit is 9.5 hours. Oversized requests fail without truncation.", "アップロード済みの音声と画像を使用します。マイク・システム音声の合計上限は9.5時間です。送信上限を超える場合は切り捨てずに停止します。")}</p>}
    <fieldset className="account-settings" disabled={saving || query.loading}>
      <label>{uiText("Summary source", "要約のソース")}<Select value={method}
        onValueChange={(value) => void save({ summary: { method: value as typeof method } })}>
        {methods.map((method) => <option key={method} value={method}>{method === "audio" ? uiText("Audio and images", "音声と画像") : uiText("Transcript and images", "文字起こしと画像")}</option>)}
      </Select></label>
      <label>{uiText("Detail", "詳細度")}<Select value={settings?.summary.detail ?? DEFAULT_ACCOUNT_SETTINGS.summary.detail}
        onValueChange={(value) => void save({ summary: { detail: value as AccountSettings["summary"]["detail"] } })}>
        {details.map((detail) => <option key={detail} value={detail}>{detailLabel(detail)}</option>)}
      </Select></label>
      <label>{uiText("Model", "モデル")}<Select value={selected?.id ?? ""} disabled={catalog.loading || !models.length}
        onValueChange={(value) => {
          const model = catalog.data?.models.find((model) => model.slug === value);
          const supported = model?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
          void saveSource({ model: value,
            reasoningEffort: (supported.includes(source.reasoningEffort) ? source.reasoningEffort
              : model?.default_reasoning_level ?? supported[0] ?? "none") as typeof source.reasoningEffort });
        }}>
        {!selected && <option value="" disabled>{uiText("Select an available model", "利用可能なモデルを選択")}</option>}
        {models.map((model) => <option key={model.id} value={model.id}>{model.display_name}</option>)}
      </Select></label>
      {catalog.error && <p role="alert" className="error">{catalog.error.message}</p>}
      {!catalog.loading && !models.length && <p>{uiText("No models available", "利用可能なモデルがありません")}</p>}
      <button className="secondary" onClick={catalog.reload} disabled={catalog.loading}>{uiText("Reload models", "モデル一覧を再取得")}</button>
      <label>{uiText("Reasoning effort", "推論強度")}<Select value={efforts.includes(source.reasoningEffort) ? source.reasoningEffort : ""} disabled={!efforts.length}
        onValueChange={(value) => void saveSource({ reasoningEffort: value as typeof source.reasoningEffort })}>
        {!efforts.includes(source.reasoningEffort) && <option value="" disabled>{uiText("Select reasoning effort", "推論強度を選択")}</option>}
        {efforts.map((effort) => <option key={effort}>{effort}</option>)}
      </Select></label>
    </fieldset>
    </section>}
    {(error || query.error) && <p role="alert" className="error">{error ?? query.error?.message} {query.error && <button className="secondary" onClick={query.reload}>{uiText("Retry", "再試行")}</button>}</p>}
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
    <div className="generation-copy"><strong><MenuIcon name="sparkles" />{uiText("AI summary", "AI 要約")}</strong><span>{uiText("Turn this conversation into clear next steps.", "会話のポイントと、次のアクションを整理します。")}</span></div>
    <div className="generation-controls">
    <Select aria-label={uiText("Summary detail", "要約の詳細度")} value={detail} disabled={active || starting}
      onValueChange={(value) => { setDetail(value); requestID.current = undefined; }}>
      <option value="">{uiText("Account default", "アカウント設定")}</option>
      {details.map((detail) => <option key={detail} value={detail}>{detailLabel(detail)}</option>)}
    </Select>
    <button className="primary" disabled={starting || active || query.loading} onClick={() => void start()}>
      {starting ? uiText("Starting…", "開始中…") : buttonLabel}
    </button>
    </div>
    {active && <span role="status">{uiText("You can close this window.", "画面を閉じても処理は続きます。")}</span>}
    {job?.status === "failed" && <span role="alert">{failureMessage}
      {job.error && <> ({job.error})</>}</span>}
    {(error || query.error) && <span role="alert">{error ?? query.error?.message}</span>}
  </div>;
}

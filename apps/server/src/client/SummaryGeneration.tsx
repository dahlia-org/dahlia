import { useEffect, useRef, useState } from "react";
import { json, uiText } from "./api";
import { refreshData, useLiveJSON } from "./live-data";
import { uuidV7 } from "../id";
import type { GatewayModelList } from "../ai-gateway/backend";
import type { AccountSettings, AccountSettingsPatch } from "../account-settings";
import type { summaryJobResponse } from "../summary/service";

type Job = ReturnType<typeof summaryJobResponse>;
const details = ["concise", "standard", "detailed", "eventSession"] as const;
const detailLabel = (detail: typeof details[number]) => ({ concise: uiText("Concise", "簡潔"), standard: uiText("Standard", "標準"),
  detailed: uiText("Detailed", "詳細"), eventSession: uiText("Event session", "イベントセッション") })[detail];

function useSummaryMethods() {
  const capabilities = useLiveJSON<{ summaryGeneration?: { version: number; methods: string[] } }>("/api/v1/capabilities");
  const summary = capabilities.data?.summaryGeneration;
  return summary?.version === 1 ? summary.methods : [];
}

export function ServerSummarySettings() {
  const methods = useSummaryMethods();
  const query = useLiveJSON<{ settings: AccountSettings | null }>("/api/v1/account/settings");
  const [error, setError] = useState<string>();
  const [saving, setSaving] = useState(false);
  const catalog = useLiveJSON<GatewayModelList>("/api/v1/models");
  const settings = query.data?.settings;

  const save = async (patch: AccountSettingsPatch) => {
    setSaving(true); setError(undefined);
    try { await json("/api/v1/account/settings", { method: "PATCH", body: JSON.stringify(patch) }); query.reload(); }
    catch (error) { setError(error instanceof Error ? error.message : uiText("Could not save settings", "設定を保存できません")); }
    finally { setSaving(false); }
  };
  const saveTranscript = (transcript: Partial<AccountSettings["summary"]["methodSettings"]["transcript"]>) =>
    save({ summary: { methodSettings: { transcript } } });
  if (!methods.includes("transcript")) return null;
  const transcript = settings?.summary.methodSettings.transcript ?? { model: "gpt-5.4", reasoningEffort: "medium" as const, detail: "detailed" as const };
  const selected = catalog.data?.data.find((model) => model.id === transcript.model || transcript.model.endsWith(`.${model.id}`));
  const metadata = catalog.data?.models.find((model) => model.slug === selected?.id);
  const efforts = metadata?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
  return <section className="section-block">
    <h2 className="section-label">{uiText("Server summary", "サーバー要約")}</h2>
    <p>{uiText("Settings apply to new jobs. Export summaries separately after generation.", "設定は次回の生成から適用されます。エクスポートは生成後に個別に行います。")}</p>
    <fieldset className="summary-settings" disabled={saving || query.loading}>
      <label>{uiText("Method", "要約方法")}<select value={settings?.summary.method ?? "transcript"}
        onChange={() => void save({ summary: { method: "transcript" } })}>
        {methods.map((method) => <option key={method} value={method}>{uiText("Transcript and images", "文字起こしと画像")}</option>)}
      </select></label>
      <label>{uiText("Model", "モデル")}<select value={selected?.id ?? ""} disabled={catalog.loading || !catalog.data?.data.length}
        onChange={(event) => {
          const model = catalog.data?.models.find((model) => model.slug === event.target.value);
          const supported = model?.supported_reasoning_levels.map(({ effort }) => effort) ?? [];
          void saveTranscript({ model: event.target.value,
            reasoningEffort: (supported.includes(transcript.reasoningEffort) ? transcript.reasoningEffort
              : model?.default_reasoning_level ?? supported[0] ?? "none") as typeof transcript.reasoningEffort });
        }}>
        {!selected && <option value="" disabled>{uiText("Select an available model", "利用可能なモデルを選択")}</option>}
        {catalog.data?.data.map((model) => <option key={model.id} value={model.id}>{model.display_name}</option>)}
      </select></label>
      {catalog.error && <p role="alert" className="error">{catalog.error.message}</p>}
      {!catalog.loading && !catalog.data?.data.length && <p>{uiText("No models available", "利用可能なモデルがありません")}</p>}
      <button onClick={catalog.reload} disabled={catalog.loading}>{uiText("Reload models", "モデル一覧を再取得")}</button>
      <label>{uiText("Reasoning effort", "推論強度")}<select value={efforts.includes(transcript.reasoningEffort) ? transcript.reasoningEffort : ""} disabled={!efforts.length}
        onChange={(event) => void saveTranscript({ reasoningEffort: event.target.value as typeof transcript.reasoningEffort })}>
        {!efforts.includes(transcript.reasoningEffort) && <option value="" disabled>{uiText("Select reasoning effort", "推論強度を選択")}</option>}
        {efforts.map((effort) => <option key={effort}>{effort}</option>)}
      </select></label>
      <label>{uiText("Detail", "詳細度")}<select value={transcript.detail}
        onChange={(event) => void saveTranscript({ detail: event.target.value as typeof transcript.detail })}>
        {details.map((detail) => <option key={detail} value={detail}>{detailLabel(detail)}</option>)}
      </select></label>
      <label>{uiText("Output language", "出力言語")}<select value={settings?.outputLanguage ?? "ja"}
        onChange={(event) => void save({ outputLanguage: event.target.value as AccountSettings["outputLanguage"] })}>
        {Object.entries({ ja: "日本語", en: "English", zh: "中文", ko: "한국어", fr: "Français", de: "Deutsch", es: "Español" }).map(([id, name]) => <option key={id} value={id}>{name}</option>)}
      </select></label>
    </fieldset>
    {(error || query.error) && <p role="alert" className="error">{error ?? query.error?.message}</p>}
  </section>;
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
    } catch (error) { setError(error instanceof Error ? error.message : uiText("Could not start summary", "要約を開始できません")); query.reload(); }
    finally { setStarting(false); }
  };
  let buttonLabel = uiText("Generate summary", "要約を生成");
  if (active) buttonLabel = uiText("Generating on server…", "サーバーで生成中…");
  else if (job?.status === "failed") buttonLabel = uiText("Retry summary", "要約を再試行");

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
    {job?.status === "failed" && <span role="alert">{job.error === "summary_input_changed"
      ? uiText("Inputs changed during generation. Retry after transcript and image processing finishes.", "生成中に入力が更新されました。文字起こし・画像処理の完了後に再試行してください。")
      : uiText("Summary failed; the existing summary was preserved.", "要約の生成に失敗しました。既存の要約は保持されています。")}
      {job.error && <> ({job.error})</>}</span>}
    {(error || query.error) && <span role="alert">{error ?? query.error?.message}</span>}
  </div>;
}

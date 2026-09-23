import { useCallback, useEffect, useRef, useState } from "react";
import { json, RequestError, uiText } from "./api";
import { apiOperations } from "./generated-operations";
import type { PreferenceSettings, Preferences, LiveStatus } from "../agent/context-model";

const labels = {
  language: ["Language", "言語"], format: ["Response format", "回答形式"], detail: ["Detail", "詳しさ"],
} as const;
const choices = {
  language: [["ja", "日本語"], ["en", "English"], ["zh", "中文"], ["ko", "한국어"], ["es", "Español"], ["fr", "Français"], ["de", "Deutsch"], ["pt", "Português"]],
  format: [["prose", uiText("Prose", "文章")], ["bullets", uiText("Bullets", "箇条書き")], ["code-first", uiText("Code first", "コードを先に")]],
  detail: [["concise", uiText("Concise", "簡潔")], ["balanced", uiText("Balanced", "標準")], ["detailed", uiText("Detailed", "詳しく")]],
};
export function ChatPreferences() {
  const [settings, setSettings] = useState<PreferenceSettings>();
  const [error, setError] = useState("");
  const [loadError, setLoadError] = useState("");
  const [explanation, setExplanation] = useState("");
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState(false);
  const [reload, setReload] = useState(0);
  const dirtyExplanation = useRef(false);
  const readRequest = useRef<AbortController | null>(null);
  useEffect(() => {
    if (busy) return;
    const controller = new AbortController();
    readRequest.current = controller;
    let loading = false;
    const refresh = async () => {
      if (loading) return;
      loading = true;
      try {
        const value = await apiOperations.getAiPreferences({ signal: controller.signal });
        if (controller.signal.aborted) return;
        setSettings(value);
        if (!dirtyExplanation.current) setExplanation(value.preferences.explanation ?? "");
        setLoadError("");
      } catch (error) {
        if (!controller.signal.aborted && !(error instanceof RequestError && error.message === "chat_memory_unavailable")) {
          setLoadError(uiText("Could not load preferences.", "好みを読み込めませんでした。"));
        }
      } finally { loading = false; }
    };
    void refresh();
    const timer = open ? setInterval(() => { void refresh(); }, 15_000) : undefined;
    return () => { controller.abort(); clearInterval(timer); };
  }, [open, busy, reload]);
  const message = error || loadError;
  if (!settings) return message ? <p role="alert">{message}</p> : null;
  async function save(next: PreferenceSettings) {
    readRequest.current?.abort();
    setBusy(true); setError("");
    try {
      const saved = await apiOperations.setAiPreferences({ body: next });
      setSettings(saved);
      return saved;
    } catch {
      setError(uiText("Could not save. Reload the preferences before retrying.", "保存できませんでした。好みを再読み込みしてから再試行してください。"));
    } finally { setBusy(false); }
  }
  async function saveExplanation(value: string) {
    dirtyExplanation.current = true;
    setExplanation(value);
    const saved = await save({ ...settings!, preferences: { ...settings!.preferences, explanation: value.trim() || null } });
    if (saved) {
      dirtyExplanation.current = false;
      setExplanation(saved.preferences.explanation ?? "");
    }
  }
  return <details className="text-xs p-2" onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>{uiText("Response preferences", "回答の好み")}</summary>
    <p>{uiText("Private preferences apply across Workspaces. Edited or cleared fields will not be automatically overwritten.", "本人専用の好みはワークスペースをまたいで使います。編集・削除した項目は自動更新で上書きしません。")}</p>
    <label><input type="checkbox" checked={settings.automatic} disabled={busy} onChange={(event) => void save({ ...settings, automatic: event.target.checked })} />{uiText("Learn preferences automatically", "好みを自動で覚える")}</label>
    <div className="flex flex-wrap gap-2 py-2">{(Object.keys(labels) as Array<Exclude<keyof Preferences, "explanation">>).map((key) => <label key={key}>
      {uiText(labels[key][0], labels[key][1])}<select className="border rounded p-1 ml-1" value={settings.preferences[key] ?? ""} disabled={busy}
        onChange={(event) => void save({ ...settings, preferences: { ...settings.preferences, [key]: event.target.value || null } })}>
        <option value="">{uiText("Not remembered", "記憶しない")}</option>
        {choices[key].map(([value, label]) => <option key={value} value={value}>{label}</option>)}
      </select>
    </label>)}</div>
    <label className="block">{uiText("Explanation preferences (no business information)", "説明の好み（業務情報は含めない）")}
      <textarea maxLength={240} rows={2} disabled={busy} value={explanation} onChange={(event) => { dirtyExplanation.current = true; setExplanation(event.target.value); }}
        placeholder={uiText("Explain technical terms on first use", "専門用語は初出時に説明してほしい")} />
    </label>
    <button type="button" disabled={busy || explanation === (settings.preferences.explanation ?? "")} onClick={() => void saveExplanation(explanation)}>{uiText("Save explanation preference", "説明の好みを保存")}</button>
    <button type="button" disabled={busy || !settings.preferences.explanation} onClick={() => void saveExplanation("")}>{uiText("Forget", "削除")}</button>
    {message && <p role="alert">{message}<button type="button" onClick={() => { setError(""); setReload((value) => value + 1); }}>{uiText("Reload", "再読み込み")}</button></p>}
  </details>;
}

type Meeting = { meetingId: string; name: string; isRecording: boolean };
export function LiveChatContext({ threadId, workspaceId, disabled }: { threadId: string; workspaceId: string; disabled: boolean }) {
  const [status, setStatus] = useState<LiveStatus>();
  const [meetings, setMeetings] = useState<Meeting[]>([]);
  const [cursor, setCursor] = useState<string>();
  const [error, setError] = useState("");
  const [loadError, setLoadError] = useState("");
  const [busy, setBusy] = useState(false);
  const [meetingError, setMeetingError] = useState("");
  const [loadingMeetings, setLoadingMeetings] = useState(false);
  const params = { path: { threadId } };
  const readRequest = useRef<AbortController | null>(null);
  const scopeRequest = useRef<AbortController | null>(null);
  const meetingRequest = useRef<AbortController | null>(null);
  const loadMeetings = useCallback(async (after?: string) => {
    const scope = scopeRequest.current!;
    meetingRequest.current?.abort();
    const controller = new AbortController();
    meetingRequest.current = controller;
    const signal = AbortSignal.any([scope.signal, controller.signal]);
    setLoadingMeetings(true);
    try {
      const page = await json<{ items: Meeting[]; nextCursor?: string }>(`/api/v1/workspaces/${workspaceId}/meetings${after ? `?cursor=${encodeURIComponent(after)}` : ""}`,
        { signal }, { notifyMutation: false });
      if (!signal.aborted) {
        setMeetings((current) => {
          const retained = current.filter((item) => !page.items.some((next) => next.meetingId === item.meetingId));
          return after ? [...retained, ...page.items] : [...page.items, ...retained];
        });
        setCursor(page.nextCursor); setMeetingError("");
      }
    } catch {
      if (!signal.aborted) setMeetingError(uiText("Could not load meetings.", "会議を読み込めませんでした。"));
    } finally { if (!signal.aborted) setLoadingMeetings(false); }
  }, [workspaceId]);
  useEffect(() => {
    if (busy) return;
    const controller = new AbortController();
    readRequest.current = controller;
    let loading = false;
    const refresh = async () => {
      if (loading) return;
      loading = true;
      try {
        const value = await apiOperations.getAiLiveContext({ params: { path: { threadId } }, signal: controller.signal });
        if (!controller.signal.aborted) { setStatus(value); setLoadError(""); }
      }
      catch (error) {
        if (!controller.signal.aborted && !(error instanceof RequestError && error.message === "chat_memory_unavailable")) {
          setStatus(undefined);
          setLoadError(uiText("Meeting context is unavailable. You can detach the meeting below.", "会議の文脈を取得できません。下で会議の紐づけを解除できます。"));
        }
      } finally { loading = false; }
    };
    void refresh();
    const timer = setInterval(() => { void refresh(); }, 15_000);
    return () => { controller.abort(); clearInterval(timer); };
  }, [threadId, workspaceId, busy]);
  useEffect(() => {
    const controller = new AbortController();
    scopeRequest.current = controller;
    setBusy(false); setStatus(undefined); setMeetings([]); setCursor(undefined); setError(""); setLoadError("");
    setMeetingError("");
    void loadMeetings();
    return () => { controller.abort(); };
  }, [threadId, workspaceId, loadMeetings]);
  const message = error || loadError;
  if (!status && !message) return null;
  const select = async (meetingId: string | null) => {
    const controller = scopeRequest.current!;
    readRequest.current?.abort();
    setBusy(true); setError("");
    try {
      await apiOperations.setAiLiveContext({ params, body: { meetingId }, signal: controller.signal });
      const value = await apiOperations.getAiLiveContext({ params, signal: controller.signal });
      if (!controller.signal.aborted) { setStatus(value); setError(""); }
    } catch { if (!controller.signal.aborted) setError(uiText("Could not update the meeting. Try again.", "会議を更新できませんでした。再試行してください。")); }
    finally { if (!controller.signal.aborted) setBusy(false); }
  };
  const stateLabels = { off: uiText("Off", "未選択"), pending: uiText("Preparing", "準備中"), ready: uiText("Up to date", "更新済み"), delayed: uiText("Catching up", "更新待ち"), ended: uiText("Meeting ended", "会議終了"), unavailable: uiText("Meeting unavailable; chat continues without its context", "会議を利用できません。会議の文脈なしでチャットを続行します") };
  return <div className="text-xs p-2">
    <label>{uiText("Live meeting context", "会議のライブ文脈")}
      <select className="border rounded p-1 ml-2 max-w-full" disabled={disabled || busy} value={status?.meetingId ?? ""}
        onFocus={() => { void loadMeetings(); }} onPointerDown={() => { void loadMeetings(); }} onChange={(event) => void select(event.target.value || null)}>
        <option value="">{uiText("No meeting", "会議を選択しない")}</option>
        {status?.meetingId && !meetings.some((m) => m.meetingId === status.meetingId) && <option value={status.meetingId}>{uiText("Selected meeting", "選択中の会議")}</option>}
        {meetings.map((meeting) => <option value={meeting.meetingId} key={meeting.meetingId}>{meeting.name}{meeting.isRecording ? uiText(" (recording)", "（録音中）") : ""}</option>)}
      </select>
    </label>
    {cursor && <button type="button" disabled={busy || loadingMeetings} onClick={() => void loadMeetings(cursor)}>{uiText("More meetings", "会議をさらに表示")}</button>}
    {meetingError && <p role="alert">{meetingError}<button type="button" disabled={loadingMeetings} onClick={() => void loadMeetings()}>{uiText("Retry", "再試行")}</button></p>}
    {status && <p role="status">{stateLabels[status.status]}{status.processedThrough ? ` · ${uiText("Processed through", "処理済み")}: ${new Date(status.processedThrough).toLocaleTimeString()}` : ""}</p>}
    {status?.status === "unavailable" && <button type="button" disabled={busy || disabled} onClick={() => void select(null)}>{uiText("Detach", "解除")}</button>}
    {message && <p role="alert">{message}<button type="button" disabled={busy || disabled} onClick={() => void select(null)}>{uiText("Detach", "解除")}</button></p>}
  </div>;
}

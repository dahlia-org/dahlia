import { useCallback, useEffect, useRef, useState } from "react";
import { json, RequestError, uiText } from "./api";
import { apiOperations } from "./generated-operations";
import type { WorkingMemorySettings, LiveStatus } from "../agent/context-model";

export function WorkingMemoryEditor() {
  const [settings, setSettings] = useState<WorkingMemorySettings>();
  const [error, setError] = useState("");
  const [loadError, setLoadError] = useState("");
  const [manual, setManual] = useState("");
  const [learned, setLearned] = useState("");
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState(false);
  const [reload, setReload] = useState(0);
  const dirtyManual = useRef(false);
  const dirtyLearned = useRef(false);
  const bases = useRef<Partial<Record<"manual" | "learned", WorkingMemorySettings>>>({});
  const accept = useCallback((value: WorkingMemorySettings) => {
    for (const section of ["manual", "learned"] as const) {
      const dirty = section === "manual" ? dirtyManual : dirtyLearned;
      if (!dirty.current || bases.current[section]?.[section] === value[section]) bases.current[section] = value;
    }
    setSettings(value);
    if (!dirtyManual.current) setManual(value.manual);
    if (!dirtyLearned.current) setLearned(value.learned);
  }, []);
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
        const value = await apiOperations.getWorkingMemory({ signal: controller.signal });
        if (controller.signal.aborted) return;
        accept(value);
        setLoadError("");
      } catch (error) {
        if (!controller.signal.aborted && !(error instanceof RequestError && error.message === "chat_memory_unavailable")) {
          setLoadError(uiText("Could not load Working Memory.", "Working Memory を読み込めませんでした。"));
        }
      } finally { loading = false; }
    };
    void refresh();
    const timer = open ? setInterval(() => { void refresh(); }, 15_000) : undefined;
    return () => { controller.abort(); clearInterval(timer); };
  }, [open, busy, reload, accept]);
  const message = error || loadError;
  if (!settings) return message ? <p role="alert">{message}</p> : null;
  async function save(section: "manual" | "learned" | "settings", content?: string, automatic?: boolean) {
    readRequest.current?.abort();
    setBusy(true); setError("");
    try {
      const body = section === "settings" ? { section, automatic: automatic!, revision: settings!.revision, explicit: true as const }
        : { section, content: content!, revision: bases.current[section]!.revision, explicit: true };
      const saved = await apiOperations.updateWorkingMemory({ body });
      if (section === "manual") dirtyManual.current = false;
      if (section === "learned") dirtyLearned.current = false;
      accept(saved);
      return saved;
    } catch {
      setError(uiText("Could not save or these notes changed elsewhere. Your draft is kept; copy it before discarding and reloading.", "保存できないか、他で同じメモが変更されています。下書きは保持しています。破棄して再読み込みする前にコピーしてください。"));
    } finally { setBusy(false); }
  }
  return <details className="text-xs p-2" onToggle={(event) => setOpen(event.currentTarget.open)}>
    <summary>{uiText("Working Memory", "Working Memory")}</summary>
    <p>{uiText("Private across Workspaces and clients. Saved notes remain after chat deletion. Only direct persistent requests are learned automatically.", "ワークスペースとクライアントをまたぐ本人専用の記憶です。チャット削除後も残ります。自動学習は継続的な依頼だけを対象にします。")}</p>
    <label><input type="checkbox" checked={settings.automatic} disabled={busy} onChange={(event) => void save("settings", undefined, event.target.checked)} />{uiText("Learn automatically", "自動で覚える")}</label>
    {settings.capacityReached && <p role="alert">{uiText("Automatic learning paused: learned notes reached capacity. Shorten them, save, then enable learning again. The last note was not added.", "学習メモの容量に達したため自動学習を停止しました。内容を整理して保存し、自動学習を再度有効にしてください。最後のメモは追加されていません。")}</p>}
    <label className="block">{uiText("Your notes (Markdown)", "手動メモ（Markdown）")}
      <textarea maxLength={6000} rows={5} disabled={busy} value={manual} onChange={(event) => { dirtyManual.current = true; setManual(event.target.value); }} />
    </label>
    <button type="button" disabled={busy || manual === settings.manual} onClick={() => void save("manual", manual)}>{uiText("Save notes", "メモを保存")}</button>
    <label className="block">{uiText("Learned notes (Markdown)", "自動学習メモ（Markdown）")}
      <textarea maxLength={6000} rows={5} disabled={busy} value={learned} onChange={(event) => { dirtyLearned.current = true; setLearned(event.target.value); }} />
    </label>
    <button type="button" disabled={busy || learned === settings.learned} onClick={() => void save("learned", learned)}>{uiText("Save learned notes", "学習メモを保存")}</button>
    {message && <p role="alert">{message}<button type="button" onClick={() => { dirtyManual.current = false; dirtyLearned.current = false; setError(""); setReload((value) => value + 1); }}>{uiText("Discard drafts and reload", "下書きを破棄して再読み込み")}</button></p>}
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

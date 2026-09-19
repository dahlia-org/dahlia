import { Brain, BriefcaseBusiness, Plus, Send, Sparkles, Square, Trash2 } from "lucide-react";
import { useEffect, useRef, useState, type KeyboardEvent } from "react";

import { json, RequestError, uiText } from "./api";
import { useActionDialog } from "./ActionDialog";
import { MenuIcon, useSidebar } from "./Sidebar";
import { DetailHeaderBar } from "./layout/AppShell";
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectTrigger,
  SelectValue,
} from "./components/ui/select";

export type Message = { id?: string; role: "user" | "assistant"; content: string; createdAt?: string };
type AiEvent = { type: "text"; text: string }
  | { type: "tool"; name: string; status: "running" | "complete" }
  | { type: "error"; code: string }
  | { type: "done" };
type ReasoningEffort = "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra";
type AiModel = {
  id: string;
  displayName: string;
  defaultReasoningEffort: ReasoningEffort;
  supportedReasoningEfforts: Array<{ effort: ReasoningEffort; description: string }>;
};
type AiThread = { id: string; title: string; workspaceId: string; createdAt: string; updatedAt: string };
type PickerOption = { value: string; label: string; description: string };

export function prependEarlierMessages(current: Message[], earlier: Message[]): Message[] {
  const known = new Set(current.flatMap(({ id }) => id ? [id] : []));
  return [...earlier.filter(({ id }) => !id || !known.has(id)), ...current];
}

export function recoverFailedDraft(stored: Message[], attempted: Message): string {
  return stored.slice(-2).some(({ role, content }) => role === "user" && content === attempted.content) ? "" : attempted.content;
}

function ComposerPicker({ kind, label, value, options, disabled, onValueChange }: {
  kind: "workspace" | "reasoning" | "model";
  label: string;
  value: string;
  options: PickerOption[];
  disabled: boolean;
  onValueChange: (value: string) => void;
}) {
  const icon = (className?: string) => kind === "workspace"
    ? <BriefcaseBusiness className={className} aria-hidden="true" />
    : kind === "reasoning" ? <Brain className={className} aria-hidden="true" />
      : <Sparkles className={className} aria-hidden="true" />;
  const selected = options.find((option) => option.value === value);
  return <Select value={value || undefined} disabled={disabled} onValueChange={onValueChange}>
    <SelectTrigger className="ai-picker-trigger" aria-label={label} data-ai-picker={kind} data-value={value}>
      {icon()}
      <SelectValue placeholder={label}>{selected?.label}</SelectValue>
    </SelectTrigger>
    <SelectContent className="ai-picker-content" align="start" side="top" sideOffset={8}>
      <SelectGroup>
        <SelectLabel className="ai-picker-label">{label}</SelectLabel>
        {options.map((option) => <SelectItem className="ai-picker-item" key={option.value} value={option.value}
          data-value={option.value}>
          {icon("ai-picker-icon")}
          <span className="ai-picker-copy"><strong>{option.label}</strong><small>{option.description}</small></span>
        </SelectItem>)}
        {!options.length && <span className="ai-picker-empty" role="status">{uiText("No options available", "選択肢がありません")}</span>}
      </SelectGroup>
    </SelectContent>
  </Select>;
}

export function AiChat() {
  const { dialog, openDialog } = useActionDialog();
  const { workspaces } = useSidebar();
  const [models, setModels] = useState<AiModel[]>([]);
  const [workspaceId, setWorkspaceId] = useState("");
  const [model, setModel] = useState("");
  const [reasoningEffort, setReasoningEffort] = useState<ReasoningEffort | "">("");
  const [messages, setMessages] = useState<Message[]>([]);
  const [draft, setDraft] = useState("");
  const [answer, setAnswer] = useState("");
  const [tool, setTool] = useState<string>();
  const [pending, setPending] = useState(false);
  const [locked, setLocked] = useState(false);
  const [error, setError] = useState<string>();
  const [historyReady, setHistoryReady] = useState(false);
  const [historyEnabled, setHistoryEnabled] = useState(false);
  const [threads, setThreads] = useState<AiThread[]>([]);
  const [threadPage, setThreadPage] = useState(0);
  const [hasMoreThreads, setHasMoreThreads] = useState(false);
  const [threadId, setThreadId] = useState<string>();
  const [hasEarlierMessages, setHasEarlierMessages] = useState(false);
  const [openingThread, setOpeningThread] = useState(false);
  const [loadingMoreThreads, setLoadingMoreThreads] = useState(false);
  const controller = useRef<AbortController | undefined>(undefined);
  const viewGeneration = useRef(0);
  const threadListGeneration = useRef(0);
  const refreshingThreads = useRef(false);
  const loadingMoreThreadsRef = useRef(false);
  const loadingEarlier = useRef(false);
  const transcript = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const request = new AbortController();
    void json<{ items: AiModel[] }>("/api/v1/ai/models", { signal: request.signal }, { notifyMutation: false })
      .then(({ items }) => { setModels(items); setModel((current) => current || items[0]?.id || ""); })
      .catch((caught: unknown) => { if (!request.signal.aborted) setError(caught instanceof Error ? caught.message : uiText("Could not load models.", "モデルを読み込めませんでした。")); });
    return () => request.abort();
  }, []);
  async function refreshThreads() {
    const generation = ++threadListGeneration.current;
    refreshingThreads.current = true;
    try {
      const result = await json<{ items: AiThread[]; hasMore: boolean }>("/api/v1/ai/threads", undefined, { notifyMutation: false });
      if (threadListGeneration.current !== generation) return;
      setHistoryEnabled(true);
      setThreads(result.items);
      setThreadPage(0);
      setHasMoreThreads(result.hasMore);
      setHistoryReady(true);
    } catch (caught) {
      if (threadListGeneration.current !== generation) return;
      if (caught instanceof RequestError && caught.status === 404) { setHistoryReady(true); return; }
      setHistoryReady(true);
      throw caught;
    } finally {
      if (threadListGeneration.current === generation) refreshingThreads.current = false;
    }
  }
  useEffect(() => {
    const requested = new URLSearchParams(location.search).get("thread");
    void refreshThreads().then(() => requested ? openThread(requested) : undefined)
      .catch((caught: unknown) => setError(caught instanceof Error ? caught.message : uiText("Could not load chat history.", "チャット履歴を読み込めませんでした。")));
  }, []);
  useEffect(() => {
    const selected = models.find(({ id }) => id === model);
    if (selected && !selected.supportedReasoningEfforts.some(({ effort }) => effort === reasoningEffort)) {
      setReasoningEffort(selected.defaultReasoningEffort);
    }
  }, [model, models, reasoningEffort]);
  useEffect(() => () => {
    controller.current?.abort("unmount");
    controller.current = undefined;
  }, []);
  useEffect(() => {
    if (!workspaceId && workspaces?.[0]) setWorkspaceId(workspaces[0].workspaceId);
  }, [workspaceId, workspaces]);
  useEffect(() => { transcript.current?.lastElementChild?.scrollIntoView({ block: "nearest" }); }, [messages, answer, tool]);
  const selectedWorkspace = workspaces?.find((workspace) => workspace.workspaceId === workspaceId);
  const persistentHistory = historyEnabled && Boolean(threadId || (selectedWorkspace && selectedWorkspace.encryption !== "server"));

  const send = async (nextMessages: Message[]) => {
    if (!historyReady || openingThread || !workspaceId || !model || !reasoningEffort || pending) return;
    const request = new AbortController();
    const generation = viewGeneration.current;
    const persist = persistentHistory;
    const current = () => viewGeneration.current === generation && controller.current === request;
    controller.current = request;
    setPending(true);
    setLocked(true);
    setError(undefined);
    setAnswer("");
    setTool(undefined);
    let responseText = "";
    let completed = false;
    let activeThreadId = threadId;
    try {
      if (persist && !activeThreadId) {
        const created = await json<AiThread>("/api/v1/ai/threads", { method: "POST",
          body: JSON.stringify({ workspaceId, title: nextMessages.at(-1)!.content }) });
        if (!current()) return;
        activeThreadId = created.id;
        setThreadId(created.id);
        setThreads((current) => [created, ...current]);
        globalThis.history.replaceState(null, "", `/ai?thread=${created.id}`);
      }
      const response = await fetch(persist ? `/api/v1/ai/threads/${activeThreadId}/messages` : "/api/v1/ai/chat", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(persist
          ? { model, reasoningEffort, content: nextMessages.at(-1)!.content }
          : { workspaceId, model, reasoningEffort, messages: nextMessages }),
        signal: request.signal,
      });
      if (!current()) return;
      if (!response.ok) {
        const detail = await response.json().catch(() => null) as { error?: string } | null;
        throw new Error(detail?.error || uiText("AI request failed.", "AIへのリクエストに失敗しました。"));
      }
      for await (const event of readAiEvents(response)) {
        if (!current()) return;
        if (event.type === "text") { responseText += event.text; setAnswer(responseText); }
        else if (event.type === "tool") setTool(event.status === "running" ? event.name : undefined);
        else if (event.type === "error") throw new Error(event.code);
        else if (event.type === "done") completed = true;
      }
      if (!current()) return;
      if (!completed || !responseText.trim()) throw new Error("stream_incomplete");
      setMessages([...nextMessages, { role: "assistant", content: responseText }]);
      setAnswer("");
      if (persist) void refreshThreads().catch(() => undefined);
    } catch (caught) {
      if (!current()) return;
      if (request.signal.reason === "stop") setError(uiText("Response stopped.", "回答を停止しました。"));
      else if (!request.signal.aborted) setError(caught instanceof Error ? caught.message : uiText("AI request failed.", "AIへのリクエストに失敗しました。"));
      if (persist && activeThreadId) {
        try {
          const { messages: stored } = await json<{ messages: Message[] }>(`/api/v1/ai/threads/${activeThreadId}`, undefined,
            { notifyMutation: false });
          if (current()) {
            setMessages(stored);
            setDraft(recoverFailedDraft(stored, nextMessages.at(-1)!));
          }
        } catch { /* Keep the visible draft when recovery is unavailable. */ }
      }
    } finally {
      if (current()) {
        controller.current = undefined;
        setPending(false);
        setTool(undefined);
      }
    }
  };
  const submit = () => {
    const content = draft.trim();
    if (!historyReady || openingThread || !content || !workspaceId || !model || !reasoningEffort || pending
      || (!persistentHistory && messages.at(-1)?.role === "user")) return;
    const next = [...messages, { role: "user" as const, content }];
    setMessages(next);
    setDraft("");
    void send(next);
  };
  const reset = () => {
    viewGeneration.current += 1;
    controller.current?.abort("reset");
    controller.current = undefined;
    setPending(false);
    setMessages([]);
    setAnswer("");
    setDraft("");
    setError(undefined);
    setLocked(false);
    setOpeningThread(false);
    setThreadId(undefined);
    setHasEarlierMessages(false);
    globalThis.history.replaceState(null, "", "/ai");
  };
  async function openThread(id: string) {
    const generation = ++viewGeneration.current;
    setOpeningThread(true);
    controller.current?.abort("open");
    controller.current = undefined;
    loadingEarlier.current = false;
    setPending(false);
    setAnswer("");
    setTool(undefined);
    setDraft("");
    setError(undefined);
    setHasEarlierMessages(false);
    try {
      const result = await json<{ thread: AiThread; messages: Message[]; hasMore: boolean }>(`/api/v1/ai/threads/${id}`, undefined,
        { notifyMutation: false });
      if (viewGeneration.current !== generation) return;
      setThreadId(id);
      setWorkspaceId(result.thread.workspaceId);
      setThreads((current) => current.some((thread) => thread.id === id) ? current : [result.thread, ...current]);
      setMessages(result.messages);
      setHasEarlierMessages(result.hasMore);
      setLocked(true);
      globalThis.history.replaceState(null, "", `/ai?thread=${id}`);
    } catch (caught) {
      if (viewGeneration.current === generation) {
        setError(caught instanceof Error ? caught.message : uiText("Could not load chat history.", "チャット履歴を読み込めませんでした。"));
      }
    } finally {
      if (viewGeneration.current === generation) setOpeningThread(false);
    }
  }
  async function loadMoreThreads() {
    if (loadingMoreThreadsRef.current || refreshingThreads.current) return;
    loadingMoreThreadsRef.current = true;
    setLoadingMoreThreads(true);
    const generation = threadListGeneration.current;
    try {
      const page = threadPage + 1;
      const result = await json<{ items: AiThread[]; hasMore: boolean }>(`/api/v1/ai/threads?page=${page}`, undefined,
        { notifyMutation: false });
      if (threadListGeneration.current !== generation) return;
      setThreads((current) => [...current, ...result.items.filter((item) => !current.some(({ id }) => id === item.id))]);
      setThreadPage(page);
      setHasMoreThreads(result.hasMore);
    } catch (caught) {
      if (threadListGeneration.current === generation) {
        setError(caught instanceof Error ? caught.message : uiText("Could not load chat history.", "チャット履歴を読み込めませんでした。"));
      }
    } finally {
      loadingMoreThreadsRef.current = false;
      setLoadingMoreThreads(false);
    }
  }
  async function loadEarlierMessages() {
    if (!threadId || pending || loadingEarlier.current) return;
    const id = threadId;
    const generation = viewGeneration.current;
    const before = messages.find(({ id, createdAt }) => id && createdAt);
    if (!before?.id || !before.createdAt) return;
    loadingEarlier.current = true;
    try {
      const query = new URLSearchParams({ before: before.createdAt, beforeId: before.id, beforeRole: before.role });
      const result = await json<{ messages: Message[]; hasMore: boolean }>(`/api/v1/ai/threads/${id}?${query}`, undefined,
        { notifyMutation: false });
      if (viewGeneration.current !== generation || threadId !== id) return;
      setMessages((current) => prependEarlierMessages(current, result.messages));
      setHasEarlierMessages(result.hasMore);
    } catch (caught) {
      if (viewGeneration.current === generation && threadId === id) {
        setError(caught instanceof Error ? caught.message : uiText("Could not load chat history.", "チャット履歴を読み込めませんでした。"));
      }
    } finally {
      if (viewGeneration.current === generation) loadingEarlier.current = false;
    }
  }
  function deleteThread(id: string) {
    openDialog({ title: uiText("Delete chat history?", "チャット履歴を削除しますか？"),
      description: uiText("This chat and its messages will be permanently deleted.", "このチャットとメッセージは完全に削除されます。"),
      confirmLabel: uiText("Delete chat", "チャットを削除"), destructive: true,
      onSubmit: async () => {
        await json(`/api/v1/ai/threads/${id}`, { method: "DELETE" });
        if (threadId === id) reset();
        await refreshThreads();
      },
    });
  }
  const retry = () => { if (messages.at(-1)?.role === "user") void send(messages); };
  const keyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
      event.preventDefault();
      submit();
    }
  };
  const workspaceOptions = workspaces?.map((workspace) => ({
    value: workspace.workspaceId,
    label: workspace.name,
    description: uiText("Meeting search scope for this chat", "このチャットで参照するミーティングの範囲"),
  })) ?? [];
  const modelOptions = models.map((item) => ({
    value: item.id,
    label: item.displayName,
    description: item.id,
  }));
  const selectedModel = models.find(({ id }) => id === model);
  const effortLabel = (effort: ReasoningEffort) => effort === "none" ? uiText("None", "なし")
    : effort === "xhigh" ? "xHigh" : effort[0]!.toUpperCase() + effort.slice(1);
  const reasoningOptions = selectedModel?.supportedReasoningEfforts.map(({ effort, description }) => ({
    value: effort,
    label: effortLabel(effort),
    description,
  })) ?? [];
  const composer = <div className="ai-composer">
    <textarea aria-label={uiText("Message", "メッセージ")} placeholder={uiText("Ask about your meetings…", "ミーティングについて質問…")} rows={messages.length ? 2 : 4}
      value={draft} disabled={pending || openingThread || !historyReady} onChange={(event) => setDraft(event.target.value)} onKeyDown={keyDown} />
    <div className="ai-composer-controls">
      <ComposerPicker kind="workspace" label={uiText("Choose Workspace", "ワークスペースを選択")}
        value={workspaceId} options={workspaceOptions} disabled={locked || pending} onValueChange={setWorkspaceId} />
      <div className="ai-composer-actions">
        <ComposerPicker kind="reasoning" label={uiText("Choose reasoning effort", "推論レベルを選択")}
          value={reasoningEffort} options={reasoningOptions} disabled={pending} onValueChange={(value) => setReasoningEffort(value as ReasoningEffort)} />
        <ComposerPicker kind="model" label={uiText("Choose model", "モデルを選択")}
          value={model} options={modelOptions} disabled={pending} onValueChange={setModel} />
        {pending
          ? <button className="ai-send" aria-label={uiText("Stop", "停止")} onClick={() => controller.current?.abort("stop")}><Square aria-hidden="true" /></button>
          : <button className="ai-send" aria-label={uiText("Send", "送信")} disabled={!historyReady || openingThread || !draft.trim() || !workspaceId || !model || !reasoningEffort || (!persistentHistory && messages.at(-1)?.role === "user")} onClick={submit}><Send aria-hidden="true" /></button>}
      </div>
    </div>
  </div>;

  return <section className={`ai-chat${messages.length ? " has-messages" : ""}${historyEnabled ? " with-history" : ""}`} aria-label="AI">
    {dialog}
    {historyEnabled && <aside className="ai-history" aria-label={uiText("Chat history", "チャット履歴")}>
      <button className="ai-history-new" onClick={reset}><Plus aria-hidden="true" />{uiText("New chat", "新しいチャット")}</button>
      {threads.map((thread) => <div className={`ai-history-row${thread.id === threadId ? " active" : ""}`} key={thread.id}>
        <button onClick={() => void openThread(thread.id)}><span>{thread.title}</span><time>{new Date(thread.updatedAt).toLocaleDateString()}</time></button>
        <button className="ai-history-delete" aria-label={uiText("Delete chat", "チャットを削除")} onClick={() => void deleteThread(thread.id)}><Trash2 aria-hidden="true" /></button>
      </div>)}
      {hasMoreThreads && <button className="secondary" disabled={loadingMoreThreads} onClick={() => void loadMoreThreads()}>{loadingMoreThreads ? uiText("Loading…", "読み込み中…") : uiText("Load more", "さらに読み込む")}</button>}
    </aside>}
    {messages.length > 0 && <header className="ai-header">
      <DetailHeaderBar>
        <div className="flex min-w-0 flex-1 items-center gap-1 whitespace-nowrap px-1.5 text-xs">
          <button className="ai-new-chat" aria-label={uiText("New chat", "新しいチャット")} onClick={reset}>
            <MenuIcon name="chat" /><span className="truncate">Dahlia AI</span>
          </button>
          <span className="text-muted-foreground" aria-hidden="true">/</span>
          <strong className="truncate">{threads.find(({ id }) => id === threadId)?.title || uiText("New chat", "新しいチャット")}</strong>
        </div>
      </DetailHeaderBar>
    </header>}
    {messages.length === 0 ? <div className="ai-start">
      <div className="ai-mark" aria-hidden="true">D</div>
      <h1>{uiText("What can I help you find?", "何をお探しですか？")}</h1>
      {composer}
      {error && <div className="ai-error mt-4 w-full" role="alert"><span>{error}</span></div>}
      <p>{persistentHistory
        ? uiText("Answers use meetings in the selected Workspace. Your chat history is saved privately.", "選択したワークスペースのミーティングから回答します。チャット履歴は非公開で保存されます。")
        : uiText("Answers use meetings in the selected Workspace. History disappears when you leave this page.", "選択したワークスペースのミーティングから回答します。履歴はページを離れると消えます。")}</p>
    </div> : <>
      <div className="ai-transcript" ref={transcript}>
        {hasEarlierMessages && <button className="secondary" disabled={openingThread || pending} onClick={() => void loadEarlierMessages()}>{uiText("Load earlier messages", "以前のメッセージを読み込む")}</button>}
        {messages.map((message, index) => <article className={`ai-message ${message.role}`} key={message.id || index}>{message.content}</article>)}
        {answer && <article className="ai-message assistant">{answer}</article>}
        {tool && <p className="ai-status" role="status">{uiText(`Checking meetings with ${tool}…`, `${tool} でミーティングを確認中…`)}</p>}
        {error && <div className="ai-error" role="alert"><span>{error}</span>{!persistentHistory && <button className="secondary" disabled={pending || openingThread || messages.at(-1)?.role !== "user"} onClick={retry}>{uiText("Retry", "再試行")}</button>}</div>}
      </div>
      <div className="ai-bottom">{composer}<p className="sr-only" aria-live="polite">{pending ? uiText("AI is responding", "AIが回答中です") : error || uiText("Ready", "準備完了")}</p></div>
    </>}
  </section>;
}

export async function* readAiEvents(response: Response): AsyncGenerator<AiEvent> {
  if (!response.body) throw new Error("stream_unavailable");
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const chunk = await reader.read();
    buffer += decoder.decode(chunk.value, { stream: !chunk.done }).replaceAll("\r\n", "\n");
    let boundary = buffer.indexOf("\n\n");
    while (boundary >= 0) {
      const block = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      const lines = block.split("\n");
      const event = lines.find((line) => line.startsWith("event:"))?.slice(6).trim();
      const data = lines.filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trimStart()).join("\n");
      if (event && data) yield { type: event, ...JSON.parse(data) } as AiEvent;
      boundary = buffer.indexOf("\n\n");
    }
    if (chunk.done) break;
  }
}

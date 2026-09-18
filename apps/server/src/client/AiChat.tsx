import { Brain, BriefcaseBusiness, Send, Sparkles, Square } from "lucide-react";
import { useEffect, useRef, useState, type KeyboardEvent } from "react";

import { json, uiText } from "./api";
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

type Message = { role: "user" | "assistant"; content: string };
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
type PickerOption = { value: string; label: string; description: string };

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
  const controller = useRef<AbortController | undefined>(undefined);
  const transcript = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const request = new AbortController();
    void json<{ items: AiModel[] }>("/api/v1/ai/models", { signal: request.signal }, { notifyMutation: false })
      .then(({ items }) => { setModels(items); setModel((current) => current || items[0]?.id || ""); })
      .catch((caught: unknown) => { if (!request.signal.aborted) setError(caught instanceof Error ? caught.message : uiText("Could not load models.", "モデルを読み込めませんでした。")); });
    return () => request.abort();
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

  const send = async (nextMessages: Message[]) => {
    if (!workspaceId || !model || !reasoningEffort || pending) return;
    const request = new AbortController();
    controller.current = request;
    setPending(true);
    setLocked(true);
    setError(undefined);
    setAnswer("");
    setTool(undefined);
    let responseText = "";
    let completed = false;
    try {
      const response = await fetch("/api/v1/ai/chat", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ workspaceId, model, reasoningEffort, messages: nextMessages }),
        signal: request.signal,
      });
      if (!response.ok) {
        const detail = await response.json().catch(() => null) as { error?: string } | null;
        throw new Error(detail?.error || uiText("AI request failed.", "AIへのリクエストに失敗しました。"));
      }
      for await (const event of readAiEvents(response)) {
        if (event.type === "text") { responseText += event.text; setAnswer(responseText); }
        else if (event.type === "tool") setTool(event.status === "running" ? event.name : undefined);
        else if (event.type === "error") throw new Error(event.code);
        else if (event.type === "done") completed = true;
      }
      if (!completed || !responseText.trim()) throw new Error("stream_incomplete");
      setMessages([...nextMessages, { role: "assistant", content: responseText }]);
      setAnswer("");
    } catch (caught) {
      if (request.signal.reason === "stop") setError(uiText("Response stopped.", "回答を停止しました。"));
      else if (!request.signal.aborted) setError(caught instanceof Error ? caught.message : uiText("AI request failed.", "AIへのリクエストに失敗しました。"));
    } finally {
      if (controller.current === request) {
        controller.current = undefined;
        setPending(false);
        setTool(undefined);
      }
    }
  };
  const submit = () => {
    const content = draft.trim();
    if (!content || !workspaceId || !model || !reasoningEffort || pending || messages.at(-1)?.role === "user") return;
    const next = [...messages, { role: "user" as const, content }];
    setMessages(next);
    setDraft("");
    void send(next);
  };
  const reset = () => {
    controller.current?.abort("reset");
    controller.current = undefined;
    setPending(false);
    setMessages([]);
    setAnswer("");
    setDraft("");
    setError(undefined);
    setLocked(false);
  };
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
      value={draft} disabled={pending} onChange={(event) => setDraft(event.target.value)} onKeyDown={keyDown} />
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
          : <button className="ai-send" aria-label={uiText("Send", "送信")} disabled={!draft.trim() || !workspaceId || !model || !reasoningEffort || messages.at(-1)?.role === "user"} onClick={submit}><Send aria-hidden="true" /></button>}
      </div>
    </div>
  </div>;

  return <section className={`ai-chat${messages.length ? " has-messages" : ""}`} aria-label="AI">
    {messages.length > 0 && <header className="ai-header">
      <DetailHeaderBar>
        <div className="flex min-w-0 flex-1 items-center gap-1 whitespace-nowrap px-1.5 text-xs">
          <button className="ai-new-chat" aria-label={uiText("New chat", "新しいチャット")} onClick={reset}>
            <MenuIcon name="chat" /><span className="truncate">Dahlia AI</span>
          </button>
          <span className="text-muted-foreground" aria-hidden="true">/</span>
          <strong className="truncate">New chat</strong>
        </div>
      </DetailHeaderBar>
    </header>}
    {messages.length === 0 ? <div className="ai-start">
      <div className="ai-mark" aria-hidden="true">D</div>
      <h1>{uiText("What can I help you find?", "何をお探しですか？")}</h1>
      {composer}
      {error && <div className="ai-error mt-4 w-full" role="alert"><span>{error}</span></div>}
      <p>{uiText("Answers use meetings in the selected Workspace. History disappears when you leave this page.", "選択したワークスペースのミーティングから回答します。履歴はページを離れると消えます。")}</p>
    </div> : <>
      <div className="ai-transcript" ref={transcript}>
        {messages.map((message, index) => <article className={`ai-message ${message.role}`} key={index}>{message.content}</article>)}
        {answer && <article className="ai-message assistant">{answer}</article>}
        {tool && <p className="ai-status" role="status">{uiText(`Checking meetings with ${tool}…`, `${tool} でミーティングを確認中…`)}</p>}
        {error && <div className="ai-error" role="alert"><span>{error}</span><button className="secondary" disabled={pending || messages.at(-1)?.role !== "user"} onClick={retry}>{uiText("Retry", "再試行")}</button></div>}
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

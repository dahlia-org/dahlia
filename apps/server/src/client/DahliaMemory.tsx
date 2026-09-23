import { useEffect, useRef, useState } from "react";
import { uuidV7 } from "../id";
import { encodeId } from "../typeid";
import { json, uiText } from "./api";
import { useActionDialog } from "./ActionDialog";
import { WorkingMemoryEditor } from "./ChatMemory";
import { Button } from "./components/ui/button";
import { Input } from "./components/ui/input";
import { MCPConnectionDialog } from "./MCPConnectionDialog";

type Scope = { scope: "personal" | "workspace"; workspaceId?: string; name: string; writable: boolean };
type Note = { id: string; content: string; revision: number; updatedAt: string; protected: boolean };
type Status = { enabled: boolean; status: string; skippedCount: number };
type Result = { sources?: Array<{ id: string; canonicalExcerpt: string; meeting_id?: string | null; truncated: boolean }>;
  hypothesis?: string | null; unavailable?: boolean; coverage?: string; canonical?: { items: Note[] } };
const memoryRequest = <T,>(scope: Scope, operation: "list" | "status" | "save" | "delete" | "configure" | "recall" | "reflect", input: Record<string, unknown>, signal?: AbortSignal) => {
  const owner = scope.workspaceId ? `/api/v1/workspaces/${scope.workspaceId}` : "/api/v1/user";
  const { id, ...edit } = input;
  let method: "GET" | "POST" | "PATCH" | "DELETE";
  let path: string;
  let data = input;
  switch (operation) {
    case "list": method = "GET"; path = "notes"; break;
    case "status": method = "GET"; path = "analysis/status"; break;
    case "save": {
      const updating = Number(input.revision) > 0;
      method = updating ? "PATCH" : "POST";
      path = updating ? `notes/${String(id)}` : "notes";
      if (updating) data = edit;
      break;
    }
    case "delete": method = "DELETE"; path = `notes/${String(id)}`; data = edit; break;
    case "configure": method = "PATCH"; path = "analysis/settings"; break;
    case "recall": method = "POST"; path = "recall"; break;
    case "reflect": method = "POST"; path = "reflect"; break;
  }
  const query = new URLSearchParams(Object.entries(data).filter(([, value]) => value !== undefined).map(([key, value]) => [key, String(value)]));
  const read = method === "GET" || method === "DELETE";
  return json<T>(`${owner}/memory/${path}${read && query.size ? `?${query}` : ""}`, { method, ...(read ? {} : { body: JSON.stringify(data) }), signal }, { notifyMutation: ["save", "delete", "configure"].includes(operation) });
};
const scopeKey = (scope: Scope) => scope.workspaceId ?? "personal";
export function DahliaMemoryPage() {
  const [connection, setConnection] = useState(false);
  const [scopes, setScopes] = useState<Scope[]>([]), [selected, setSelected] = useState("personal"), [error, setError] = useState(false);
  useEffect(() => {
    const controller = new AbortController();
    void json<{ scopes: Scope[] }>("/api/v1/user/memory/scopes", { signal: controller.signal }).then((value) => setScopes(value.scopes))
      .catch(() => { if (!controller.signal.aborted) setError(true); });
    return () => controller.abort();
  }, []);
  const current = scopes.find((s) => scopeKey(s) === selected);
  return <main className="mx-auto grid w-full max-w-4xl gap-5 p-6">
    <h1 className="text-2xl font-semibold">Dahlia Memory</h1>
    <p>{uiText("Your knowledge, across AI tools. Personal memories stay private; Workspace memories are shared with its members.", "AI ツールを跨いで使える記憶。個人の記憶は非公開、Workspace の記憶はそのメンバーに共有されます。")}</p>
    {error && <p role="alert">{uiText("Could not load memory. Reload to retry.", "記憶を読み込めません。再読み込みしてください。")}</p>}
    <label className="grid gap-1 text-sm">{uiText("Memory scope", "記憶の保存先")}<select className="rounded-md border bg-background px-3 py-2" value={selected} onChange={(e) => setSelected(e.target.value)}>
      {scopes.map((s) => <option key={scopeKey(s)} value={scopeKey(s)}>{s.scope === "personal" ? uiText("Personal (only you)", "個人（自分のみ）") : s.name}</option>)}
    </select></label>
    {current && <MemoryPanel key={selected} scope={current} scopes={scopes} />}
    <WorkingMemoryEditor />
    <p>{uiText("Configure your MCP client to recall related memories before work and save useful personal lessons. Shared saves and deletion require your explicit instruction.", "MCP クライアントには、作業前の関連記憶の検索と有用な個人の記憶の保存を指示してください。共有への保存と削除には明示的な依頼が必要です。")}</p>
    <Button variant="outline" onClick={() => setConnection(true)}>{uiText("Connect an AI tool", "AI ツールを接続")}</Button>
    {connection && <MCPConnectionDialog memory onClose={() => setConnection(false)} />}
  </main>;
}
function MemoryPanel({ scope, scopes }: { scope: Scope; scopes: Scope[] }) {
  const [notes, setNotes] = useState<Note[]>([]), [next, setNext] = useState<string | null>(null), [query, setQuery] = useState(""), [listedQuery, setListedQuery] = useState("");
  const [status, setStatus] = useState<Status>(), [error, setError] = useState(""), [busy, setBusy] = useState(false), [reload, setReload] = useState(0);
  const [results, setResults] = useState<Result[]>([]);
  const activeRead = useRef<AbortController | undefined>(undefined);
  const { dialog, openDialog } = useActionDialog();
  useEffect(() => {
    const controller = new AbortController();
    const read = new AbortController(); activeRead.current = read;
    setResults([]); setBusy(false);
    const loadStatus = () => memoryRequest<Status>(scope, "status", {}, controller.signal).then(setStatus).catch(() => {
      if (!controller.signal.aborted) setError(uiText("Could not read analysis status.", "分析の状態を取得できません。"));
    });
    void memoryRequest<{ items: Note[]; nextCursor: string | null }>(scope, "list", {}, read.signal).then((v) => { if (!read.signal.aborted) { setNotes(v.items); setNext(v.nextCursor); setListedQuery(""); } })
      .catch(() => { if (!read.signal.aborted) setError(uiText("Could not read memories.", "記憶を取得できません。")); });
    void loadStatus();
    const timer = setInterval(() => void loadStatus(), 10_000);
    return () => { controller.abort(); activeRead.current?.abort(); clearInterval(timer); };
    // scope is fixed for this keyed panel.
  }, [reload]);
  const failure = () => setError(uiText("The operation failed or this memory changed. Reload before retrying; your edit has not been discarded.", "操作に失敗したか、記憶が変更されています。再読み込みして確認してください。編集中の内容は破棄していません。"));
  const edit = (note?: Note, destination = scope) => {
    const existing = destination === scope ? note : undefined;
    const id = existing ? existing.id : encodeId("sharedMemory", uuidV7());
    openDialog({
      title: existing ? uiText("Edit memory", "記憶を編集") : uiText("Save memory", "記憶を保存"),
      description: destination.scope === "personal" ? uiText("Only you can read this memory.", "この記憶は自分だけが読めます。") : uiText(`Share with members of ${destination.name}.`, `${destination.name} のメンバーに共有します。`),
      confirmLabel: uiText("Save", "保存"), fields: [{ name: "content", label: uiText("Memory", "記憶"), value: note?.content ?? "", multiline: true, required: true }],
      onSubmit: async ({ content }) => {
        await memoryRequest(destination, "save", { content,
          id, revision: existing ? existing.revision : 0, explicit: true });
        setReload((v) => v + 1);
      },
    });
  };
  const remove = (note: Note) => openDialog({ title: uiText("Delete memory", "記憶を削除"), description: note.content,
    confirmLabel: uiText("Delete", "削除"), destructive: true, onSubmit: async () => {
      await memoryRequest(scope, "delete", { id: note.id, revision: note.revision, explicit: true }); setReload((v) => v + 1);
    } });
  const configure = () => openDialog({ title: status?.enabled ? uiText("Pause analysis", "分析を停止") : uiText("Enable analysis", "分析を有効化"),
    description: uiText("Saved memories are processed by the configured external memory service. Pausing keeps your saved notes available.", "保存した記憶を設定済みの外部メモリーサービスで処理します。停止後も保存した記憶は管理できます。"),
    confirmLabel: uiText("Confirm", "確認"), onSubmit: async () => { setStatus(await memoryRequest<Status>(scope, "configure", { enabled: !status?.enabled })); } });
  const search = async (mode: "list" | "recall" | "reflect", after?: string) => {
    activeRead.current?.abort();
    const controller = new AbortController(); activeRead.current = controller;
    setBusy(true); setError("");
    try {
      if (mode === "list") {
        const result = await memoryRequest<{ items: Note[]; nextCursor: string | null }>(scope, mode, { query: after ? listedQuery : query.trim(), after }, controller.signal);
        if (controller.signal.aborted) return;
        setNotes((items) => after ? [...items, ...result.items] : result.items); setNext(result.nextCursor); setListedQuery(after ? listedQuery : query.trim()); setResults([]);
      } else {
        const result = await memoryRequest<{ results: Array<{ result: Result }> }>(scope, mode, { query: query.trim() }, controller.signal);
        if (controller.signal.aborted) return;
        setResults(result.results.map((r) => r.result));
      }
    } catch { if (!controller.signal.aborted) failure(); } finally { if (!controller.signal.aborted) setBusy(false); }
  };
  return <section className="workspace-settings grid gap-3" aria-label="Dahlia Memory">
    <h2>{scope.scope === "personal" ? uiText("Personal · Only you", "個人 · 自分のみ") : `${scope.name} · ${uiText("Shared", "共有")}`}</h2>
    <p role="status">{uiText("Analysis", "分析")}: {status ? ({ ready: uiText("Ready", "利用可能"), paused: uiText("Paused", "停止中"), pending: uiText("Pending", "取り込み待ち"), indexing: uiText("Updating", "更新中"), partial: uiText("Partial coverage", "一部のみ"), error: uiText("Retrying", "再試行中"), deleting: uiText("Deleting", "削除中"), unavailable: uiText("Not configured", "未設定") }[status.status] ?? uiText("Updating", "更新中")) : uiText("Loading", "読み込み中")}</p>
    {!!status?.skippedCount && <p role="alert">{uiText(`${status.skippedCount} sources were skipped.`, `${status.skippedCount} 件を取り込めませんでした。`)}</p>}
    {error && <p role="alert">{error}</p>}
    <div className="flex flex-wrap items-end gap-2">
      {scope.writable && <Button variant="outline" onClick={() => edit()}>{uiText("Add memory", "記憶を追加")}</Button>}
      {scope.scope === "personal" && status?.status !== "unavailable" && <Button variant="outline" onClick={configure}>{status?.enabled ? uiText("Pause analysis", "分析を停止") : uiText("Enable analysis", "分析を有効化")}</Button>}
      {scope.workspaceId && <a href={`/workspaces/${scope.workspaceId}`}>{uiText("Workspace settings", "Workspace 設定")}</a>}
      <Button variant="outline" onClick={() => { setQuery(""); setResults([]); setReload((v) => v + 1); }}>{uiText("Reload", "再読み込み")}</Button>
    </div>
    <form className="flex flex-wrap items-end gap-2" onSubmit={(e) => { e.preventDefault(); void search("list"); }}>
      <label className="grid gap-1 text-sm">{uiText("Search memories", "記憶を検索")}<Input value={query} maxLength={4000} onChange={(e) => setQuery(e.target.value)} /></label>
      <Button variant="outline" disabled={busy}>{uiText("Text search", "本文検索")}</Button>
      <Button variant="outline" type="button" disabled={busy || !query.trim()} onClick={() => void search("recall")}>{uiText("Related memories", "関連する記憶")}</Button>
      <Button variant="outline" type="button" disabled={busy || !query.trim()} onClick={() => void search("reflect")}>{uiText("Insights", "示唆")}</Button>
    </form>
    {results.map((result, i) => <section key={i} className="panel">
      {result.unavailable && <p role="status">{uiText("Analysis is unavailable. Literal matches are shown; these are not complete semantic results.", "分析を利用できません。本文の一致だけを表示しています。関連する記憶の全件ではありません。")}</p>}
      {result.coverage && result.coverage !== "ready" && <p role="status">{uiText("Memory coverage is incomplete or updating.", "記憶は一部のみ、または更新中です。")}</p>}
      {result.hypothesis && <><h3>{uiText("Interpretation · verify sources", "解釈 · 出典で確認してください")}</h3><p className="whitespace-pre-wrap">{result.hypothesis}</p></>}
      {result.sources?.map((source) => <article key={source.id}><h3>{source.meeting_id ? <a href={`/meetings/${source.meeting_id}`}>{uiText("Source meeting", "出典の会議")}</a> : uiText("Saved memory", "保存された記憶")}</h3><p className="whitespace-pre-wrap">{source.canonicalExcerpt}</p>{source.truncated && <p>{uiText("Excerpt only", "抜粋のみ")}</p>}</article>)}
      {result.canonical?.items.map((note) => <p key={note.id} className="whitespace-pre-wrap">{note.content}</p>)}
    </section>)}
    {!notes.length && <p>{uiText("No saved memories in this list.", "この一覧に記憶はありません。")}</p>}
    {notes.map((note) => <article key={note.id} className="panel grid gap-2">
      <p className="whitespace-pre-wrap">{note.content}</p>
      <small>{new Date(note.updatedAt).toLocaleString()} · {note.protected ? uiText("Human edited", "ユーザーが編集") : uiText("AI saved", "AI が保存")}</small>
      {scope.writable && <div className="flex flex-wrap items-end gap-2"><Button variant="outline" onClick={() => edit(note)}>{uiText("Edit", "編集")}</Button><Button variant="outline" onClick={() => remove(note)}>{uiText("Delete", "削除")}</Button>
        {scope.scope === "personal" && scopes.some((s) => s.scope === "workspace" && s.writable) && <label className="grid gap-1 text-sm">{uiText("Share a copy", "コピーを共有")}<select className="rounded-md border bg-background px-3 py-2" value="" onChange={(e) => { const destination = scopes.find((s) => scopeKey(s) === e.target.value); if (destination) edit(note, destination); }}>
          <option value="">{uiText("Choose Workspace", "Workspace を選択")}</option>{scopes.filter((s) => s.scope === "workspace" && s.writable).map((s) => <option key={s.workspaceId} value={s.workspaceId}>{s.name}</option>)}
        </select></label>}
      </div>}
    </article>)}
    {next && <Button variant="outline" disabled={busy} onClick={() => void search("list", next)}>{uiText("Load more", "続きを表示")}</Button>}
    {dialog}
  </section>;
}

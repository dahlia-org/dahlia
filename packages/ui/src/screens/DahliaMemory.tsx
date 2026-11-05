import { objectPath } from "../model/object-url";
import { PageHeader } from "../layout/AppShell";
import { useEffect, useId, useRef, useState } from "react";
import type { components } from "../api/generated-api";

type Note = components["schemas"]["DahliaMemoryNote"];
import { uuidV7 } from "../model/id";
import { encodeId } from "../model/typeid";
import { json, RequestError, uiText } from "../api/api";
import { useActionDialog } from "./ActionDialog";
import { WorkingMemoryEditor } from "./ChatMemory";
import { Button } from "../components/ui/button";
import { Input } from "../components/ui/input";
import { MCPConnectionDialog } from "./MCPConnectionDialog";

type Scope = { scope: "personal" | "workspace"; workspaceId?: string; name: string; writable: boolean };
const memoryRequest = <T,>(scope: Scope, operation: "list" | "save" | "delete" | "recall", input: Record<string, unknown>, signal?: AbortSignal) => {
  const owner = scope.workspaceId ? `/api/v1/workspaces/${scope.workspaceId}` : "/api/v1/user";
  const { id, ...edit } = input;
  let method: "GET" | "POST" | "PATCH" | "DELETE";
  let path: string;
  let data = input;
  switch (operation) {
    case "list": method = "GET"; path = "notes"; break;
    case "save": {
      const updating = Number(input.revision) > 0;
      method = updating ? "PATCH" : "POST";
      path = updating ? `notes/${String(id)}` : "notes";
      if (updating) data = edit;
      break;
    }
    case "delete": method = "DELETE"; path = `notes/${String(id)}`; data = edit; break;
    case "recall": method = "POST"; path = "recall"; break;
  }
  const query = new URLSearchParams(Object.entries(data).filter(([, value]) => value !== undefined).map(([key, value]) => [key, String(value)]));
  const read = method === "GET" || method === "DELETE";
  return json<T>(`${owner}/memory/${path}${read && query.size ? `?${query}` : ""}`, { method, ...(read ? {} : { body: JSON.stringify(data) }), signal }, { notifyMutation: ["save", "delete"].includes(operation) });
};
const scopeKey = (scope: Scope) => scope.workspaceId ?? "personal";
const typeLabel = (type: Note["type"]) => ({
  profile: uiText("Profile", "プロフィール"), preference: uiText("Preference", "好み"), work: uiText("Work", "仕事"),
  people: uiText("People", "人物"), notes: uiText("Notes", "メモ"),
})[type];
const memoryTypes: Note["type"][] = ["profile", "preference", "work", "people", "notes"];
export function DahliaMemoryPage() {
  const [connection, setConnection] = useState(false);
  const [scopes, setScopes] = useState<Scope[]>([]), [selected, setSelected] = useState(() => new URLSearchParams(location.search).get("workspaceId") ?? "personal"), [error, setError] = useState(false);
  useEffect(() => {
    const controller = new AbortController();
    void json<{ scopes: Scope[] }>("/api/v1/user/memory/scopes", { signal: controller.signal }).then((value) => setScopes(value.scopes))
      .catch(() => { if (!controller.signal.aborted) setError(true); });
    return () => controller.abort();
  }, []);
  const current = scopes.find((s) => scopeKey(s) === selected);
  return <main className="mx-auto grid w-full max-w-4xl gap-5 p-6">
    <PageHeader title="Dahlia Memory" />
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
  const [error, setError] = useState(""), [busy, setBusy] = useState(false), [reload, setReload] = useState(0);
  const [related, setRelated] = useState<Note[]>();
  const activeRead = useRef<AbortController | undefined>(undefined);
  const searchHint = useId();
  const { dialog, openDialog } = useActionDialog();
  useEffect(() => {
    const read = new AbortController(); activeRead.current = read;
    setRelated(undefined); setBusy(false);
    void memoryRequest<{ items: Note[]; nextCursor: string | null }>(scope, "list", {}, read.signal).then(async (value) => {
      const link = new URLSearchParams(location.search);
      const noteId = link.get("workspaceId") === scope.workspaceId ? link.get("noteId") : null;
      if (scope.workspaceId && noteId) {
        try {
          const { memory } = await json<{ memory: Note }>(`/api/v1/workspaces/${scope.workspaceId}/memory/notes/${encodeURIComponent(noteId)}`, { signal: read.signal });
          value.items = [memory, ...value.items.filter((item) => item.id !== memory.id)];
        } catch (error) {
          if (!(error instanceof RequestError) || error.status !== 404) throw error;
          // The optional note may be gone; recheck the list and its current authorization before displaying it.
          value = await memoryRequest<{ items: Note[]; nextCursor: string | null }>(scope, "list", {}, read.signal);
        }
      }
      if (!read.signal.aborted) { setNotes(value.items); setNext(value.nextCursor); setListedQuery(""); }
    }).catch(() => { if (!read.signal.aborted) setError(uiText("Could not read memories.", "記憶を取得できません。")); });
    return () => { activeRead.current?.abort(); };
    // scope is fixed for this keyed panel.
  }, [reload]);
  const failure = () => setError(uiText("The operation failed or this memory changed. Reload before retrying; your edit has not been discarded.", "操作に失敗したか、記憶が変更されています。再読み込みして確認してください。編集中の内容は破棄していません。"));
  const edit = (note?: Note, destination = scope) => {
    const existing = destination === scope ? note : undefined;
    const id = existing ? existing.id : encodeId("sharedMemory", uuidV7());
    openDialog({
      title: existing ? uiText("Edit memory", "記憶を編集") : uiText("Save memory", "記憶を保存"),
      description: destination.scope === "personal" ? uiText("Only you can read this memory.", "この記憶は自分だけが読めます。") : uiText(`Share with members of ${destination.name}.`, `${destination.name} のメンバーに共有します。`),
      confirmLabel: uiText("Save", "保存"), fields: [
        { name: "type", label: uiText("Type", "種類"), value: note?.type ?? "notes", options: memoryTypes.map((type) => ({ value: type, label: typeLabel(type) })) },
        { name: "content", label: uiText("Memory", "記憶"), value: note?.content ?? "", multiline: true, required: true }],
      onSubmit: async ({ type, content }) => {
        await memoryRequest(destination, "save", { type, content,
          id, revision: existing ? existing.revision : 0, explicit: true });
        setReload((v) => v + 1);
      },
    });
  };
  const remove = (note: Note) => openDialog({ title: uiText("Delete memory", "記憶を削除"), description: note.content,
    confirmLabel: uiText("Delete", "削除"), destructive: true, onSubmit: async () => {
      await memoryRequest(scope, "delete", { id: note.id, revision: note.revision, explicit: true }); setReload((v) => v + 1);
    } });
  const search = async (mode: "list" | "recall", after?: string) => {
    activeRead.current?.abort();
    const controller = new AbortController(); activeRead.current = controller;
    setBusy(true); setError("");
    try {
      if (mode === "list") {
        const result = await memoryRequest<{ items: Note[]; nextCursor: string | null }>(scope, mode, { query: after ? listedQuery : query.trim(), after }, controller.signal);
        if (controller.signal.aborted) return;
        setNotes((items) => after ? [...items, ...result.items] : result.items); setNext(result.nextCursor); setListedQuery(after ? listedQuery : query.trim()); setRelated(undefined);
      } else {
        const result = await memoryRequest<{ results: Array<{ items: Note[] }> }>(scope, mode, { query: query.trim() }, controller.signal);
        if (controller.signal.aborted) return;
        setRelated(result.results.flatMap((r) => r.items));
      }
    } catch { if (!controller.signal.aborted) failure(); } finally { if (!controller.signal.aborted) setBusy(false); }
  };
  return <section className="workspace-settings grid gap-3" aria-label="Dahlia Memory">
    <h2>{scope.scope === "personal" ? uiText("Personal · Only you", "個人 · 自分のみ") : `${scope.name} · ${uiText("Shared", "共有")}`}</h2>
    {error && <p role="alert">{error}</p>}
    <div className="flex flex-wrap items-end gap-2">
      {scope.writable && <Button variant="outline" onClick={() => edit()}>{uiText("Add memory", "記憶を追加")}</Button>}
      {scope.workspaceId && <a href={objectPath(scope.workspaceId)}>{uiText("Workspace settings", "Workspace 設定")}</a>}
      <Button variant="outline" onClick={() => { setQuery(""); setRelated(undefined); setReload((v) => v + 1); }}>{uiText("Reload", "再読み込み")}</Button>
    </div>
    <form className="flex flex-wrap items-end gap-2" onSubmit={(e) => { e.preventDefault(); void search("list"); }}>
      <label className="grid gap-1 text-sm">{uiText("Search memories", "記憶を検索")}<Input value={query} maxLength={4000} aria-describedby={searchHint} onChange={(e) => setQuery(e.target.value)} /></label>
      <Button variant="outline" disabled={busy}>{uiText("Text search", "本文検索")}</Button>
      <Button variant="outline" type="button" disabled={busy || !query.trim()} onClick={() => void search("recall")}>{uiText("Related memories", "関連する記憶")}</Button>
    </form>
    <p id={searchHint} className="text-xs text-muted-foreground">{uiText("Text search finds memories containing the typed text as one phrase. Related memories accepts a question or keywords and ranks memories by matching words and, when the Server has embeddings configured, by meaning.", "本文検索は入力した文字列をひと続きで含む記憶を探します。関連する記憶は質問文やキーワードを受け付け、一致する語と（Server で埋め込みが設定されていれば）意味の近さで並べます。")}</p>
    {related && <section className="panel grid gap-2" aria-label={uiText("Related memories", "関連する記憶")}>
      <h3>{uiText("Related memories · best matches first", "関連する記憶 · 関連度順")}</h3>
      {!related.length && <p>{uiText("No related saved memory was found.", "関連する記憶は見つかりませんでした。")}</p>}
      {related.map((note) => <p key={note.id} className="whitespace-pre-wrap">{note.content}</p>)}
    </section>}
    {!notes.length && <p>{uiText("No saved memories in this list.", "この一覧に記憶はありません。")}</p>}
    {notes.map((note) => <article key={note.id} id={`note-${note.id}`} className="panel grid gap-2">
      <p className="whitespace-pre-wrap">{note.content}</p>
      <small>{typeLabel(note.type)} · {new Date(note.updatedAt).toLocaleString()} · {note.protected ? uiText("Human edited", "ユーザーが編集") : uiText("AI saved", "AI が保存")}</small>
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

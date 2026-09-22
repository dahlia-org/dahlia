import { uuidV7 } from "../id";
import { encodeId } from "../typeid";
import { useEffect, useState } from "react";
import { json, RequestError, uiText } from "./api";
import { useActionDialog } from "./ActionDialog";

type MemoryStatus = { enabled: boolean; status: string; errorCode: string | null; attempts: number };
type Note = { id: string; content: string; revision: number; updatedAt: string };
const statusLabel = (status: string) => ({
  ready: uiText("Ready", "記憶済み"), paused: uiText("Paused", "停止中"), pending: uiText("Pending", "登録待ち"),
  indexing: uiText("Learning from saved data", "保存データを取り込み中"), error: uiText("Retrying after an error", "エラー・再試行待ち"),
  deleting: uiText("Deleting memories", "記憶を削除中"),
})[status] ?? uiText("Pending", "登録待ち");

export function WorkspaceMemory({ workspaceId, role, compact = false, onEnabledWorkspace }: { workspaceId: string; role: string; compact?: boolean; onEnabledWorkspace?: (id: string) => void }) {
  const [status, setStatus] = useState<MemoryStatus>();
  const [notes, setNotes] = useState<Note[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [unavailable, setUnavailable] = useState(false);
  const [error, setError] = useState<string>();
  const { dialog, openDialog } = useActionDialog();
  const url = `/api/v1/workspaces/${workspaceId}/memory`;
  useEffect(() => {
    if (!workspaceId) return;
    let alive = true;
    setStatus(undefined); setNotes([]); setUnavailable(false); setError(undefined);
    onEnabledWorkspace?.("");
    const load = async () => {
      try {
        const result = await json<MemoryStatus>(url);
        if (alive) { setStatus(result); onEnabledWorkspace?.(result.enabled ? workspaceId : ""); }
      } catch (error) {
        if (alive) {
          onEnabledWorkspace?.("");
          if (error instanceof RequestError && error.status === 404) setUnavailable(true);
          else setError(uiText("Could not read memory status", "メモリー状態を取得できません"));
        }
      }
    };
    void load();
    const timer = setInterval(() => void load(), 10_000);
    return () => { alive = false; clearInterval(timer); };
  }, [url, workspaceId, onEnabledWorkspace]);
  const loadNotes = async (after?: string) => {
    const result = await json<{ items: Note[]; nextCursor: string | null }>(`${url}/notes${after ? `?after=${after}` : ""}`);
    setNotes((current) => after ? [...current, ...result.items] : result.items); setNextCursor(result.nextCursor);
  };
  const configure = (enabled: boolean) => openDialog({
    title: enabled ? uiText("Enable Workspace memory", "Workspace メモリーを有効化") : uiText("Pause Workspace memory", "Workspace メモリーを停止"),
    description: enabled ? uiText("Saved and future completed meetings will be processed by the configured memory service and used by members of this Workspace.", "既存および今後終了する会議を設定済みメモリーサービスで処理し、この Workspace のメンバーが利用できるようにします。")
      : uiText("Stored memories are kept. Reading and ingestion stop.", "記憶を保持したまま、参照と取り込みを停止します。"),
    confirmLabel: enabled ? uiText("Enable / retry", "有効化・再試行") : uiText("Pause", "停止"),
    onSubmit: async () => { await json(url, { method: "PUT", body: JSON.stringify({ enabled }) }); setStatus(await json<MemoryStatus>(url)); },
  });
  if (unavailable) return compact ? null : <p>{uiText("Workspace memory is unavailable on this server.", "このサーバーでは Workspace メモリーを利用できません。")}</p>;
  return <section className="workspace-settings" aria-label={uiText("Workspace memory", "Workspace メモリー")}>
    {!compact && <h2>{uiText("Workspace memory", "Workspace メモリー")}</h2>}
    <p role="status">{status ? statusLabel(status.status) : uiText("Loading memory status…", "メモリー状態を確認中…")}</p>
    {error && <p role="alert">{error}</p>}
    {!compact && <>
      <p>{uiText("Facts are verified against saved Dahlia data. Shared notes are user-provided information, not verified meeting facts.", "事実は Dahlia の保存データで確認します。共有メモはユーザーが登録した情報であり、会議で確認された事実とは区別します。")}</p>
      {status?.errorCode && <p role="alert">{uiText("Processing failed. Retry or check the server connection and Workspace administrator access.", "処理に失敗しました。再試行するか、サーバーの接続設定とWorkspace 管理者の権限を確認してください。")}</p>}
      {role === "admin" && <div className="actions">
        <button className="secondary" onClick={() => configure(!status?.enabled)}>{status?.enabled ? uiText("Pause", "停止") : uiText("Enable", "有効化")}</button>
        {status?.enabled && <button className="secondary" onClick={() => configure(true)}>{uiText("Retry", "再試行")}</button>}
        <button className="secondary" onClick={() => openDialog({ title: uiText("Erase Workspace memory", "Workspace メモリーを全削除"),
          description: uiText("This deletes shared notes and learned memories. Meetings in Dahlia are preserved.", "共有メモと学習した記憶を削除します。Dahlia の会議データは保持されます。"),
          confirmLabel: uiText("Erase", "全削除"), destructive: true,
          onSubmit: async () => { await json(url, { method: "DELETE" }); setNotes([]); setStatus(await json<MemoryStatus>(url)); },
        })}>{uiText("Erase memories", "記憶を全削除")}</button>
      </div>}
      <button className="secondary" onClick={() => void loadNotes().catch(() => setError(uiText("Could not load notes", "共有メモを取得できません")))}>{uiText("Show shared notes", "共有メモを表示")}</button>
      {notes.map((note) => <article key={note.id}><p style={{ whiteSpace: "pre-wrap" }}>{note.content}</p>
        {role !== "viewer" && <>
          <button className="secondary" onClick={() => openDialog({ title: uiText("Edit shared information", "共有情報を訂正"),
            confirmLabel: uiText("Save for this Workspace", "この Workspace に保存"),
            fields: [{ name: "content", label: uiText("Shared content", "共有する内容"), value: note.content, multiline: true, required: true }],
            onSubmit: async ({ content }) => { await json(`${url}/notes`, { method: "PUT", body: JSON.stringify({ id: note.id, revision: note.revision, content, confirmed: true }) }); await loadNotes(); },
          })}>{uiText("Edit", "訂正")}</button>
          <button className="secondary" onClick={() => openDialog({ title: uiText("Delete shared information", "共有情報を削除"), confirmLabel: uiText("Delete", "削除"), destructive: true,
            onSubmit: async () => { await json(`${url}/notes/${note.id}?revision=${note.revision}`, { method: "DELETE" }); await loadNotes(); },
          })}>{uiText("Delete", "削除")}</button>
        </>}
      </article>)}
      {nextCursor && <button className="secondary" onClick={() => void loadNotes(nextCursor).catch(() => setError(uiText("Could not load notes", "共有メモを取得できません")))}>{uiText("Load more", "さらに表示")}</button>}
    </>}
    {dialog}
  </section>;
}

export function SaveSharedMemory({ workspaceId, workspaceName, content }: { workspaceId: string; workspaceName: string; content: string }) {
  const { dialog, openDialog } = useActionDialog();
  const [saved, setSaved] = useState(false);
  return <><button className="secondary" disabled={saved} onClick={() => {
    const id = encodeId("sharedMemory", uuidV7());
    openDialog({ title: uiText("Save shared information", "共有情報として記憶"),
      description: uiText(`All members of ${workspaceName} can use this information. Review the text; the rest of this private chat is not shared.`, `${workspaceName} の全メンバーが利用できる情報として保存します。内容を確認してください。この非公開チャットの他の内容は共有されません。`),
      confirmLabel: uiText("Share and remember", "共有して記憶"),
      fields: [{ name: "content", label: uiText("Shared content", "共有する内容"), value: content, multiline: true, required: true }],
      onSubmit: async ({ content }) => { await json(`/api/v1/workspaces/${workspaceId}/memory/notes`, { method: "PUT", body: JSON.stringify({ id, content, revision: 0, confirmed: true }) }); setSaved(true); },
    });
  }}>{saved ? uiText("Saved · memory pending", "保存済み・記憶登録待ち") : uiText("Share to Workspace memory", "Workspace に共有して記憶")}</button>{dialog}</>;
}

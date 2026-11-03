import { uuidV7 } from "../model/id";
import { encodeId } from "../model/typeid";
import { useEffect, useId, useState } from "react";
import { json, uiText } from "../api/api";
import { useActionDialog, type DialogField } from "./ActionDialog";
import { generateMemoryDraft } from "../api/memory-draft";
import { Button } from "../components/ui/button";
import { Brain, BookmarkPlus } from "lucide-react";

type Note = { id: string; content: string; revision: number; updatedAt: string };
export function WorkspaceMemory({ workspaceId, role }: { workspaceId: string; role: string }) {
  const id = useId();
  const [notesOpen, setNotesOpen] = useState(false);
  const [notesLoading, setNotesLoading] = useState(false);
  const [notesLoaded, setNotesLoaded] = useState(false);
  const [notesError, setNotesError] = useState<string>();
  const [notes, setNotes] = useState<Note[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const { dialog, openDialog } = useActionDialog();
  const url = `/api/v1/workspaces/${workspaceId}/memory`;
  useEffect(() => {
    if (!workspaceId) return;
    setNotes([]); setNextCursor(null); setNotesOpen(false); setNotesLoaded(false); setNotesError(undefined);
  }, [url, workspaceId]);
  const loadNotes = async (after?: string) => {
    setNotesLoading(true); setNotesError(undefined);
    try {
      const result = await json<{ items: Note[]; nextCursor: string | null }>(`${url}/notes${after ? `?after=${after}` : ""}`);
      setNotes((current) => after ? [...current, ...result.items] : result.items);
      setNextCursor(result.nextCursor); setNotesLoaded(true);
    } catch {
      setNotesError(uiText("Could not load shared notes. Try again.", "共有メモを読み込めませんでした。再試行してください。"));
    } finally { setNotesLoading(false); }
  };
  const admin = role === "admin";
  const erase = () => openDialog({
    title: uiText("Erase Workspace memory", "ワークスペースメモリーを全削除"),
    description: uiText("This deletes every shared note in this Workspace. Meetings in Dahlia are preserved.", "このワークスペースの共有メモをすべて削除します。Dahlia の会議データは保持されます。"),
    confirmLabel: uiText("Erase", "全削除"), destructive: true,
    onSubmit: async () => { await json(url, { method: "DELETE" }); setNotes([]); setNextCursor(null); },
  });
  return <section className="workspace-settings space-y-4" aria-labelledby={`${id}-heading`}>
    <div className="space-y-1.5">
      <h2 id={`${id}-heading`} className="flex items-center gap-2"><Brain className="size-4 text-muted-foreground" aria-hidden="true" />{uiText("Workspace memory", "ワークスペースメモリー")}</h2>
      <p className="text-sm leading-6 text-muted-foreground">{uiText("Shared notes that members and AI tools saved for this Workspace. AI answers search them alongside meetings.", "メンバーや AI ツールがこのワークスペースに保存した共有メモです。AI はミーティングと合わせて検索します。")}</p>
    </div>
    <section className="rounded-xl border bg-card" aria-labelledby={`${id}-notes-heading`}>
      <div className="flex flex-wrap items-center justify-between gap-3 p-5">
        <div className="space-y-1"><h3 id={`${id}-notes-heading`} className="text-sm font-medium">{uiText("Shared notes", "共有メモ")}</h3>
          <p className="text-xs leading-5 text-muted-foreground">{uiText("Information saved by members. Verify meeting facts against the original record.", "メンバーが登録した情報です。会議の事実は元の記録で確認してください。")}</p></div>
        <Button variant="outline" size="sm" aria-expanded={notesOpen} aria-controls={`${id}-notes`} onClick={() => { setNotesOpen(!notesOpen); if (!notesOpen && !notesLoaded) void loadNotes(); }}>{notesOpen ? uiText("Hide notes", "閉じる") : uiText("Show shared notes", "共有メモを表示")}</Button>
      </div>
      {notesOpen && <div id={`${id}-notes`} className="space-y-4 border-t p-5">
        {notesLoading && <p role="status" className="text-sm text-muted-foreground">{uiText("Loading notes…", "共有メモを読み込み中…")}</p>}
        {notesError && <div role="alert" className="flex flex-wrap items-center gap-3 text-sm"><p>{notesError}</p><Button variant="outline" size="sm" disabled={notesLoading} onClick={() => void loadNotes()}>{uiText("Retry", "再試行")}</Button></div>}
        {notesLoaded && !notesLoading && !notesError && notes.length === 0 && <p className="text-sm text-muted-foreground">{uiText("No shared notes yet. Notes explicitly shared from chats or AI tools will appear here.", "共有メモはまだありません。チャットや AI ツールから明示的に共有したメモがここに表示されます。")}</p>}
        {notes.map((note) => <article key={note.id} className="space-y-3 rounded-lg bg-secondary/50 p-4">
          <p className="whitespace-pre-wrap break-words text-sm leading-6">{note.content}</p>
          {role !== "viewer" && <div className="flex gap-2">
            <Button variant="outline" size="sm" onClick={() => openDialog({ title: uiText("Edit shared information", "共有情報を訂正"),
              confirmLabel: uiText("Save for this Workspace", "この Workspace に保存"),
              fields: [{ name: "content", label: uiText("Shared content", "共有する内容"), value: note.content, multiline: true, required: true }],
              onSubmit: async ({ content }) => { await json(`${url}/notes/${note.id}`, { method: "PATCH", body: JSON.stringify({ revision: note.revision, content, explicit: true }) }); await loadNotes(); },
            })}>{uiText("Edit", "訂正")}</Button>
            <Button variant="ghost" size="sm" className="text-destructive" onClick={() => openDialog({ title: uiText("Delete shared information", "共有情報を削除"), confirmLabel: uiText("Delete", "削除"), destructive: true,
              onSubmit: async () => { await json(`${url}/notes/${note.id}?revision=${note.revision}&explicit=true`, { method: "DELETE" }); await loadNotes(); },
            })}>{uiText("Delete", "削除")}</Button>
          </div>}
        </article>)}
        {nextCursor && <Button variant="outline" size="sm" disabled={notesLoading} onClick={() => void loadNotes(nextCursor)}>{uiText("Load more", "さらに表示")}</Button>}
      </div>}
    </section>
    {admin && <details className="rounded-xl border px-5 py-4">
      <summary className="cursor-pointer text-sm font-medium text-muted-foreground">{uiText("Delete memory data", "メモリーデータの削除")}</summary>
      <div className="mt-4 flex flex-wrap items-center justify-between gap-4">
        <p className="max-w-lg text-xs leading-5 text-muted-foreground">{uiText("Permanently delete all shared notes in this Workspace. Meeting records are kept.", "このワークスペースの共有メモをすべて削除します。ミーティングの記録は削除されません。")}</p>
        <Button variant="outline" size="sm" className="text-destructive hover:text-destructive" onClick={erase}>{uiText("Erase memories", "記憶を全削除")}</Button>
      </div>
    </details>}
    {dialog}
  </section>;

}

export function SaveSharedMemory({ workspaceId, workspaceName, content, question, model }: { workspaceId: string; workspaceName: string; content: string; question?: string; model: string }) {
  const { dialog, openDialog } = useActionDialog();
  const [saved, setSaved] = useState(false);
  const openShareDialog = () => {
    const id = encodeId("sharedMemory", uuidV7());
    const contentField: DialogField = {
      name: "content", label: uiText("Shared content", "共有する内容"), value: content, multiline: true, required: true,
    };
    if (!model) {
      contentField.description = uiText("Select a model in chat before generating a draft. You can still edit and share this text.", "文面を生成するには、チャットでモデルを選択してください。本文の編集と共有はそのまま利用できます。");
    } else if (question) {
      contentField.description = uiText("Generation uses the corresponding question, this answer and your current edits.", "生成には、この回答に対応する質問・回答・編集中の本文を使います。");
      contentField.generate = {
        label: uiText("Generate memory draft", "記憶用の文面を生成"),
        run: (draft, signal) => generateMemoryDraft(model, { question, answer: content, draft }, signal),
      };
    } else {
      contentField.description = uiText("Load earlier messages to include the question and generate a draft.", "質問を含めて文面を生成するには、以前のメッセージを読み込んでください。");
    }
    openDialog({ title: uiText("Save shared information", "共有情報として記憶"),
      description: uiText(`All members of ${workspaceName} can use this information. Generate a draft from this question and answer, or edit the text yourself. Only the text you confirm is shared; generation alone does not save it.`, `${workspaceName} の全メンバーが利用できる情報として保存します。質問と回答から文面を生成するか、直接編集できます。確認した本文だけを共有します。生成だけでは保存されません。`),
      confirmLabel: uiText("Share and remember", "共有して記憶"),
      fields: [contentField],
      onSubmit: async ({ content }) => { await json(`/api/v1/workspaces/${workspaceId}/memory/notes`, { method: "POST", body: JSON.stringify({ id, content, revision: 0, explicit: true }) }); setSaved(true); },
    });
  };
  return <><Button variant="ghost" size="sm" className="mt-2 h-7 gap-1.5 px-2 text-xs text-muted-foreground" title={uiText("Share this answer to Workspace memory", "この回答を Workspace に共有して記憶")} disabled={saved} onClick={openShareDialog}>
    <BookmarkPlus aria-hidden="true" />{saved ? uiText("Saved", "保存済み") : uiText("Share to memory", "共有して記憶")}</Button>{dialog}</>;
}

import { uuidV7 } from "../id";
import { encodeId } from "../typeid";
import { useEffect, useId, useState } from "react";
import { json, RequestError, uiText } from "./api";
import { useActionDialog, type DialogField } from "./ActionDialog";
import { generateMemoryDraft } from "./memory-draft";
import { Switch } from "./components/ui/switch";
import { Button } from "./components/ui/button";
import { Brain, CircleAlert, RefreshCw, BookmarkPlus } from "lucide-react";

type MemoryStatus = { imagesEnabled?: boolean; imagesAvailable?: boolean; enabled: boolean; status: string; errorCode: string | null; attempts: number; skippedCount: number; skippedSources: Array<{ source: string; code: string }> };
type Note = { id: string; content: string; revision: number; updatedAt: string };
const statusLabel = (status: string) => ({
  unavailable: uiText("Analysis is not configured", "分析は未設定です"),
  partial: uiText("Ready with skipped sources", "一部の対象を除いて記憶済み"),
  ready: uiText("Ready", "記憶済み"), paused: uiText("Paused", "停止中"), pending: uiText("Pending", "登録待ち"),
  indexing: uiText("Learning from saved data", "保存データを取り込み中"), error: uiText("Retrying after an error", "エラー・再試行待ち"),
  deleting: uiText("Deleting memories", "記憶を削除中"),
})[status] ?? uiText("Pending", "登録待ち");

export function WorkspaceMemory({ workspaceId, role, compact = false, onEnabledWorkspace }: { workspaceId: string; role: string; compact?: boolean; onEnabledWorkspace?: (id: string) => void }) {
  const [statusRetry, setStatusRetry] = useState(0);
  const [status, setStatus] = useState<MemoryStatus>();
  const id = useId();
  const [notesOpen, setNotesOpen] = useState(false);
  const [notesLoading, setNotesLoading] = useState(false);
  const [notesLoaded, setNotesLoaded] = useState(false);
  const [notesError, setNotesError] = useState<string>();
  const [notes, setNotes] = useState<Note[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [unavailable, setUnavailable] = useState(false);
  const [error, setError] = useState<string>();
  const { dialog, openDialog } = useActionDialog();
  const url = `/api/v1/workspaces/${workspaceId}/memory`;
  useEffect(() => {
    if (!workspaceId) return;
    setStatus(undefined); setNotes([]); setNextCursor(null); setNotesOpen(false); setNotesLoaded(false); setNotesError(undefined); setUnavailable(false); setError(undefined);
  }, [url, workspaceId]);
  useEffect(() => {
    if (!workspaceId) return;
    let alive = true;
    onEnabledWorkspace?.("");
    const load = async () => {
      try {
        const result = await json<MemoryStatus>(`${url}/analysis/status`);
        if (alive) { setUnavailable(false); setError(undefined); setStatus(result); onEnabledWorkspace?.(result.enabled ? workspaceId : ""); }
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
  }, [url, workspaceId, onEnabledWorkspace, statusRetry]);
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
  const configure = (enabled: boolean) => openDialog({
    title: enabled ? uiText("Enable Workspace memory", "ワークスペースメモリーを有効化") : uiText("Pause Workspace memory", "ワークスペースメモリーを停止"),
    description: enabled ? uiText("Saved and future completed meetings will be processed by the configured memory service and used by members of this Workspace.", "既存および今後終了する会議を設定済みメモリーサービスで処理し、この Workspace のメンバーが利用できるようにします。")
      : uiText("Saved notes remain available. Analysis and ingestion stop.", "保存したメモは引き続き管理できます。分析と取り込みを停止します。"),
    confirmLabel: enabled ? uiText("Enable / retry", "有効化・再試行") : uiText("Pause", "停止"),
    onSubmit: async () => { setStatus(await json<MemoryStatus>(`${url}/analysis/settings`, { method: "PATCH", body: JSON.stringify({ enabled }) })); },
  });
  const configureImages = () => openDialog({
    title: status?.imagesEnabled ? uiText("Disable screenshot analysis", "画像の取り込みを無効化") : uiText("Enable screenshot analysis", "画像の取り込みを有効化"),
    description: uiText("Selected screenshots are sent to the configured vision model. Existing meetings are reprocessed; canonical images, OCR and captions are preserved.", "選別したスクリーンショットを設定済みの画像対応モデルへ送信します。既存会議も再処理し、正本画像・OCR・caption は保持します。"),
    confirmLabel: uiText("Save", "保存"), onSubmit: async () => { setStatus(await json<MemoryStatus>(`${url}/analysis/settings`, {
      method: "PATCH", body: JSON.stringify({ enabled: status?.enabled ?? false, imagesEnabled: !status?.imagesEnabled }),
    })); },
  });
  const admin = role === "admin";
  const deleting = status?.status === "deleting";
  const canConfigure = !!status && status.status !== "unavailable" && !deleting && !error;
  const needsRetry = !!status && (status.status === "error" || status.status === "partial" || !!status.errorCode);
  const erase = () => openDialog({
    title: uiText("Erase Workspace memory", "ワークスペースメモリーを全削除"),
    description: uiText("This deletes shared notes and learned memories. Meetings in Dahlia are preserved.", "共有メモと学習した記憶を削除します。Dahlia の会議データは保持されます。"),
    confirmLabel: uiText("Erase", "全削除"), destructive: true,
    onSubmit: async () => { await json(url, { method: "DELETE" }); setNotes([]); setNextCursor(null); setStatus(await json<MemoryStatus>(`${url}/analysis/status`)); },
  });
  if (unavailable) return compact ? null : <section className="workspace-settings"><h2>{uiText("Workspace memory", "ワークスペースメモリー")}</h2><p className="mt-3 text-sm text-muted-foreground">{uiText("Workspace memory is unavailable on this server.", "このサーバーではワークスペースメモリーを利用できません。")}</p></section>;
  if (compact && !error && !status?.skippedCount) return null;
  if (compact) return <section className="workspace-settings" aria-label={uiText("Workspace memory", "Workspace メモリー")}>
    {error && <p role="alert">{error}</p>}
    {!!status?.skippedCount && <p role="alert">{uiText(`${status.skippedCount} memory items were skipped. Correct the source or connection, then retry.`, `${status.skippedCount} 件を取り込めませんでした。元データや接続を修正し、再試行してください。`)}</p>}
  </section>;
  return <section className="workspace-settings space-y-4" aria-labelledby={`${id}-heading`}>
    <div className="space-y-1.5">
      <h2 id={`${id}-heading`} className="flex items-center gap-2"><Brain className="size-4 text-muted-foreground" aria-hidden="true" />{uiText("Workspace memory", "ワークスペースメモリー")}</h2>
      <p className="text-sm leading-6 text-muted-foreground">{uiText("Use saved meetings and shared notes as context for AI answers in this Workspace.", "保存したミーティングや共有メモを、このワークスペースの AI の回答に活用します。")}</p>
    </div>
    <div className="rounded-xl border bg-card">
      <div className="flex flex-wrap items-center justify-between gap-3 border-b px-5 py-4">
        <h3 className="text-sm font-medium">{uiText("Analysis status", "取り込み状況")}</h3>
        <span role="status" className={`rounded-full px-2.5 py-1 text-xs font-medium ${needsRetry ? "bg-amber-50 text-amber-900" : "bg-secondary text-muted-foreground"}`}>
          {status ? statusLabel(status.status) : uiText("Loading…", "確認中…")}
        </span>
      </div>
      {(error || needsRetry || status?.status === "unavailable") && <div className="m-5 flex items-start gap-3 rounded-lg border border-amber-200 bg-amber-50/60 p-4" role="alert">
        <CircleAlert className="mt-0.5 size-4 shrink-0 text-amber-800" aria-hidden="true" />
        <div className="min-w-0 flex-1 space-y-3 text-sm leading-6">
          <p>{error ?? (status?.status === "unavailable"
            ? uiText("Ask your server administrator to configure memory analysis. Saved shared notes can still be managed below.", "分析を利用するにはサーバー管理者による設定が必要です。保存済みの共有メモは下で管理できます。")
            : uiText("Some data could not be processed. Check the connection and access settings, then retry. Saved meetings are preserved.", "一部のデータを取り込めませんでした。接続設定とアクセス権限を確認して再試行してください。保存済みのミーティングは保持されています。"))}</p>
          {error && <Button variant="outline" size="sm" onClick={() => setStatusRetry((value) => value + 1)}>{uiText("Reload status", "状態を再取得")}</Button>}
          {admin && canConfigure && status.enabled && needsRetry && <Button variant="outline" size="sm" onClick={() => configure(true)}><RefreshCw aria-hidden="true" />{uiText("Retry", "再試行")}</Button>}
        </div>
      </div>}
      {!!status?.skippedCount && <details className="mx-5 mb-5 rounded-lg border p-3 text-xs leading-6">
        <summary className="cursor-pointer font-medium">{uiText(`${status.skippedCount} skipped items`, `取り込めなかったデータ：${status.skippedCount} 件`)}</summary>
        <ul className="mt-2 space-y-2 break-words text-muted-foreground">{status.skippedSources.map((item) => <li key={item.source}>{item.source}: {item.code === "memory_source_too_large" ? uiText("Source exceeds 4 MiB", "元データが 4 MiB を超えています")
          : item.code === "memory_policy_blocked" ? uiText("Blocked by Gateway policy", "Gateway ポリシーにより拒否されました")
          : item.code === "memory_no_facts" ? uiText("No facts were extracted", "情報を抽出できませんでした")
          : uiText("Processing failed after retries", "再試行後も処理に失敗しました")}</li>)}</ul>
        {status.skippedCount > status.skippedSources.length && <p>{uiText("Showing up to 20 items.", "最大 20 件を表示しています。")}</p>}
      </details>}
      <div className="divide-y px-5">
        <div className="flex items-start justify-between gap-5 py-5">
          <div className="space-y-1"><label htmlFor={`${id}-analysis`} className="text-sm font-medium">{uiText("Learn from meetings", "ミーティングから記憶する")}</label>
            <p id={`${id}-analysis-description`} className="max-w-lg text-xs leading-5 text-muted-foreground">{uiText("Analyze existing and future completed meetings for everyone in this Workspace. Pausing stops analysis and ingestion; saved notes remain.", "既存と今後終了するミーティングを分析し、メンバー共通の記憶として活用します。停止すると分析と取り込みが止まり、保存済みのメモは残ります。")}</p></div>
          {admin ? <Switch id={`${id}-analysis`} aria-describedby={`${id}-analysis-description`} checked={status?.enabled ?? false} disabled={!canConfigure} onCheckedChange={configure} />
            : <span className="shrink-0 text-xs text-muted-foreground">{status ? status.enabled ? uiText("Enabled", "有効") : uiText("Paused", "停止中") : "—"}</span>}
        </div>
        <div className="flex items-start justify-between gap-5 py-5">
          <div className="space-y-1"><label htmlFor={`${id}-images`} className="text-sm font-medium">{uiText("Include screenshots", "スクリーンショットも取り込む")}</label>
            <p id={`${id}-images-description`} className="max-w-lg text-xs leading-5 text-muted-foreground">{uiText("Use selected meeting screenshots as visual context. Enabling this also reprocesses existing meetings.", "選別したミーティングのスクリーンショットを画像の文脈として利用します。有効にすると既存のミーティングも再処理します。")}</p>
            {status && !status.imagesAvailable && !status.imagesEnabled && <p className="text-xs text-muted-foreground">{uiText("Screenshot analysis is not configured on this server.", "このサーバーでは画像の取り込みが設定されていません。")}</p>}</div>
          {admin ? <Switch id={`${id}-images`} aria-describedby={`${id}-images-description`} checked={status?.imagesEnabled ?? false} disabled={!canConfigure || !(status?.imagesAvailable || status?.imagesEnabled)} onCheckedChange={configureImages} />
            : <span className="shrink-0 text-xs text-muted-foreground">{status ? status.imagesEnabled ? uiText("Enabled", "有効") : uiText("Disabled", "無効") : "—"}</span>}
        </div>
      </div>
      {!admin && <p className="border-t px-5 py-3 text-xs text-muted-foreground">{uiText("Only Workspace administrators can change analysis settings.", "分析の設定はワークスペース管理者が変更できます。")}</p>}
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
        <p className="max-w-lg text-xs leading-5 text-muted-foreground">{uiText("Permanently delete all shared notes and learned memories in this Workspace. Meeting records are kept.", "このワークスペースの共有メモと学習した記憶をすべて削除します。ミーティングの記録は削除されません。")}</p>
        <Button variant="outline" size="sm" className="text-destructive hover:text-destructive" disabled={!status || deleting || !!error} onClick={erase}>{uiText("Erase memories", "記憶を全削除")}</Button>
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

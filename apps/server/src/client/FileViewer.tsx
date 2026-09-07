import { useEffect, useRef, useState, type ReactNode } from "react";
import { uiText } from "./api";
import { useLiveJSON } from "./live-data";

interface FileInfo {
  id: string;
  name: string;
  content_type: string;
  variants: { thumb_1568?: string };
  metadata: { caption?: string | null };
}

export function FileViewer({ fileId, separateTab = false }: { fileId: string; separateTab?: boolean }) {
  const query = useLiveJSON<FileInfo>(`/api/v1/files/${fileId}`);
  const file = query.data;
  const [failed, setFailed] = useState(false);
  const content = `/api/v1/files/${fileId}/content`;
  useEffect(() => setFailed(false), [file]);

  let preview: ReactNode = null;
  if (file) {
    if (!["image/png", "image/jpeg", "image/webp", "image/gif", "image/avif"].includes(file.content_type)
      && !(file.content_type === "image/tiff" && file.variants.thumb_1568)) {
      preview = <p className="content-empty">{uiText("Download this file to view its contents.", "ダウンロードしてファイルの内容を確認してください。")}</p>;
    } else if (failed) {
      preview = <p className="error" role="alert">
        {uiText("Unable to load preview.", "プレビューを読み込めません。")} <button onClick={() => { setFailed(false); query.reload(); }}>{uiText("Retry", "再試行")}</button>
      </p>;
    } else {
      preview = <img className="file-preview-image" src={file.variants.thumb_1568 ?? content} alt={file.metadata.caption || file.name} onError={() => setFailed(true)} />;
    }
  }

  return <section className="file-viewer" aria-label={uiText("File preview", "ファイルプレビュー")}>
    <header className="file-toolbar">
      <strong>{file?.name ?? uiText("File", "ファイル")}</strong>
      <div>{separateTab && <a className="secondary" href={`/files/${fileId}`} target="_blank" rel="noreferrer">{uiText("Open in new tab", "別タブで開く")}</a>}
        {file && <a className="secondary" href={content} download={file.name}>{uiText("Download", "ダウンロード")}</a>}</div>
    </header>
    {query.error && <p className="error" role="alert">{uiText("Unable to load this file. It may have been deleted or access has changed.", "ファイルを読み込めません。削除されたか、アクセス権が変更された可能性があります。")} <button onClick={query.reload}>{uiText("Retry", "再試行")}</button></p>}
    {!file && !query.error && <p className="content-empty">{uiText("Loading…", "読み込み中…")}</p>}
    {preview}
  </section>;
}

export function FileLink({ fileId, label, children }: { fileId: string; label: string; children: ReactNode }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const link = useRef<HTMLAnchorElement>(null);
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (!open) return;
    const element = dialog.current!;
    element.showModal();
    const overflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => { element.close(); document.body.style.overflow = overflow; };
  }, [open]);
  return <>
    <a ref={link} href={`/files/${fileId}`} aria-label={label} onClick={(event) => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      setOpen(true);
    }}>{children}</a>
    {open && <dialog ref={dialog} className="file-dialog" aria-label={uiText("File preview", "ファイルプレビュー")}
      onClose={() => { setOpen(false); link.current?.focus({ preventScroll: true }); }}
      onClick={(event) => { if (event.target === event.currentTarget) dialog.current?.close(); }}>
      <div className="file-dialog-content">
        <button autoFocus className="file-close secondary" onClick={() => dialog.current?.close()}>{uiText("Close", "閉じる")} <span aria-hidden="true">×</span></button>
        <FileViewer fileId={fileId} separateTab />
      </div>
    </dialog>}
  </>;
}

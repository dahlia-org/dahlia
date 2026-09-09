import { useEffect, useRef, useState, type MouseEvent, type ReactNode } from "react";
import { uiText } from "./api";
import { useLiveJSON } from "./live-data";

interface FileInfo {
  id: string;
  revision: number;
  name: string;
  content_type: string;
  size?: number;
  variants: { thumb_1568?: string };
  metadata: { caption: string | null; ocr_text: string | null; width?: number; height?: number };
}

function ViewerIcon({ path }: { path: string }) {
  return <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={path} /></svg>;
}

export function FileViewer({ fileId, separateTab = false, capturedAt, onClose }: { fileId: string; separateTab?: boolean; capturedAt?: string | null; onClose?: () => void }) {
  const query = useLiveJSON<FileInfo>(`/api/v1/files/${fileId}/metadata`);
  const file = query.data;
  const [failed, setFailed] = useState(false);
  const [infoOpen, setInfoOpen] = useState(false);
  const [zoom, setZoom] = useState(100);
  const [copyStatus, setCopyStatus] = useState("");
  const previewImage = useRef<HTMLImageElement>(null);
  const content = `/api/v1/files/${fileId}`;
  useEffect(() => setFailed(false), [file]);
  useEffect(() => { setZoom(100); setInfoOpen(false); setCopyStatus(""); }, [fileId]);

  function closeOnBackdropClick(event: MouseEvent<HTMLElement>) {
    if (event.target !== event.currentTarget) return;
    const image = previewImage.current;
    if (event.currentTarget === image) {
      const bounds = image.getBoundingClientRect();
      const scale = Math.min(bounds.width / image.naturalWidth, bounds.height / image.naturalHeight);
      const horizontalInset = (bounds.width - image.naturalWidth * scale) / 2;
      const verticalInset = (bounds.height - image.naturalHeight * scale) / 2;
      const insideImage = event.clientX >= bounds.left + horizontalInset && event.clientX <= bounds.right - horizontalInset
        && event.clientY >= bounds.top + verticalInset && event.clientY <= bounds.bottom - verticalInset;
      if (insideImage) return;
    }
    onClose?.();
  }

  async function copyImage() {
    try {
      const img = previewImage.current;
      if (!img?.complete || !img.naturalWidth) throw new Error("image_unavailable");
      const canvas = document.createElement("canvas");
      canvas.width = img.naturalWidth;
      canvas.height = img.naturalHeight;
      const context = canvas.getContext("2d");
      if (!context) throw new Error("canvas_unavailable");
      context.drawImage(img, 0, 0);
      const png = new Promise<Blob>((resolve, reject) => {
        canvas.toBlob((blob) => {
          if (blob) resolve(blob);
          else reject(new Error("copy_failed"));
        }, "image/png");
      });
      await navigator.clipboard.write([new ClipboardItem({ "image/png": png })]);
      setCopyStatus(uiText("Image copied", "画像をコピーしました"));
    } catch {
      setCopyStatus(uiText("Unable to copy image. Try downloading it instead.", "画像をコピーできません。ダウンロードをご利用ください。"));
    }
  }

  const supportedImage = !!file && (["image/png", "image/jpeg", "image/webp", "image/gif", "image/avif"].includes(file.content_type)
    || (file.content_type === "image/tiff" && !!file.variants.thumb_1568));
  let preview: ReactNode = null;
  if (file) {
    if (!supportedImage) {
      preview = <p className="content-empty">{uiText("Download this file to view its contents.", "ダウンロードしてファイルの内容を確認してください。")}</p>;
    } else if (failed) {
      preview = <p className="error" role="alert">
        {uiText("Unable to load preview.", "プレビューを読み込めません。")} <button className="secondary" onClick={() => { setFailed(false); query.reload(); }}>{uiText("Retry", "再試行")}</button>
      </p>;
    } else {
      preview = <img ref={previewImage} className="file-preview-image" src={file.variants.thumb_1568 ?? content} alt={file.metadata.caption || file.name} onError={() => setFailed(true)} onClick={closeOnBackdropClick} />;
    }
  }

  const infoLabel = uiText("Image information", "画像情報");
  const copyLabel = uiText("Copy image", "画像をコピー");
  const downloadLabel = uiText("Download", "ダウンロード");
  return <section className={`file-viewer${infoOpen && file ? " has-info" : ""}`} aria-label={uiText("File preview", "ファイルプレビュー")}
    onClick={closeOnBackdropClick}>
    <header className="file-toolbar" onClick={closeOnBackdropClick}>
      <button className="file-action" title={infoLabel} aria-label={infoLabel} aria-expanded={infoOpen} onClick={() => setInfoOpen(!infoOpen)} disabled={!file}><ViewerIcon path="M12 8h.01M11 11h1v6h1M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z" /></button>
      <button className="file-action" title={copyLabel} aria-label={copyLabel} disabled={!supportedImage || failed} onClick={() => void copyImage()}><ViewerIcon path="M9 3h10v14H9zM9 7H5v14h10v-4" /></button>
      {file && <a className="file-action" title={downloadLabel} aria-label={downloadLabel} href={content} download={file.name}><ViewerIcon path="M12 3v13m-5-5 5 5 5-5M5 20h14" /></a>}
      {onClose && <button autoFocus className="file-action" title={uiText("Close", "閉じる")} aria-label={uiText("Close", "閉じる")} onClick={onClose}><ViewerIcon path="m6 6 12 12M18 6 6 18" /></button>}
    </header>
    <div className="file-stage" onClick={closeOnBackdropClick}>
      {query.error && <p className="error file-load-error" role="alert">{uiText("Unable to load this file. It may have been deleted or access has changed.", "ファイルを読み込めません。削除されたか、アクセス権が変更された可能性があります。")} <button className="secondary" onClick={query.reload}>{uiText("Retry", "再試行")}</button></p>}
      {!file && !query.error && <p className="content-empty">{uiText("Loading…", "読み込み中…")}</p>}
      {file && <div className="file-image-size" style={{ width: `${zoom}%`, height: `${zoom}%` }}>{preview}</div>}
    </div>
    {infoOpen && file && <aside className="file-info" aria-label={infoLabel}>
      <h2>{infoLabel}</h2>
      <dl>
        {capturedAt && <><dt>{uiText("Captured", "撮影日時")}</dt><dd>{new Date(capturedAt).toLocaleString()}</dd></>}
        <dt>{uiText("File format", "ファイル形式")}</dt><dd>{file.content_type}</dd>
        {file.size !== undefined && <><dt>{uiText("File size", "ファイルサイズ")}</dt><dd>{new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(file.size / 1024)} kB</dd></>}
        {file.metadata.width && file.metadata.height && <><dt>{uiText("Image size", "画像サイズ")}</dt><dd>{file.metadata.width} × {file.metadata.height}</dd></>}
      </dl>
      <h2>{uiText("Image description", "画像の説明")}</h2><p>{file.metadata.caption || uiText("No description", "説明はありません")}</p>
      <h2>{uiText("Detected text", "検出したテキスト")}</h2><p>{file.metadata.ocr_text || uiText("No detected text", "検出したテキストはありません")}</p>
      <p className="file-info-name">{file.name}</p>
      {separateTab && <a href={`/files/${fileId}`} target="_blank" rel="noreferrer">{uiText("Open in new tab", "別タブで開く")}</a>}
    </aside>}
    <footer className="file-zoom" aria-label={uiText("Zoom", "ズーム")}>
      <button aria-label={uiText("Zoom out", "縮小")} disabled={!supportedImage || zoom <= 25} onClick={() => setZoom(Math.max(25, zoom - 25))}>−</button>
      <button title={uiText("Fit to view", "画面に合わせる")} onClick={() => setZoom(100)}>{zoom}%</button>
      <button aria-label={uiText("Zoom in", "拡大")} disabled={!supportedImage || zoom >= 400} onClick={() => setZoom(Math.min(400, zoom + 25))}>+</button>
    </footer>
    {copyStatus && <p className="file-copy-status" role="status">{copyStatus}</p>}
  </section>;
}

export function FileLink({ fileId, label, children, capturedAt }: { fileId: string; label: string; children: ReactNode; capturedAt?: string | null }) {
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
        <FileViewer key={fileId} fileId={fileId} capturedAt={capturedAt} separateTab onClose={() => dialog.current?.close()} />
      </div>
    </dialog>}
  </>;
}

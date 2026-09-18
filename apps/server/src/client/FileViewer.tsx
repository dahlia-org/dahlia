import { apiUrls } from "./generated-operations";
import { apiQuery } from "./live-data";
import { useEffect, useRef, useState, type MouseEvent, type ReactNode } from "react";
import { uiText } from "./api";
import { useLiveJSON } from "./live-data";
import { Dialog, DialogContent } from "./components/ui/dialog";
import { Tooltip } from "./Tooltip";

type FileInfo = import("./generated-api").components["schemas"]["File"];

function ViewerIcon({ path }: { path: string }) {
  return <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={path} /></svg>;
}

export function FileViewer({ fileId, separateTab = false, capturedAt, onClose, onPrevious, onNext }: {
  fileId: string;
  separateTab?: boolean;
  capturedAt?: string | null;
  onClose?: () => void;
  onPrevious?: () => void;
  onNext?: () => void;
}) {
  const query = useLiveJSON<FileInfo>(apiQuery("getFile", { params: { path: { fileId: fileId } } }));
  const file = query.data;
  const [failed, setFailed] = useState(false);
  const [infoOpen, setInfoOpen] = useState(false);
  const [zoom, setZoom] = useState(100);
  const [copyStatus, setCopyStatus] = useState("");
  const previewImage = useRef<HTMLImageElement>(null);
  const content = apiUrls.getFileContent({ params: { path: { fileId } } });
  useEffect(() => setFailed(false), [file]);
  useEffect(() => { setZoom(100); setInfoOpen(false); setCopyStatus(""); }, [fileId]);
  useEffect(() => {
    if (!onPrevious && !onNext) return;
    const navigate = (event: globalThis.KeyboardEvent) => {
      let action: (() => void) | undefined;
      if (event.key === "ArrowLeft") action = onPrevious;
      else if (event.key === "ArrowRight") action = onNext;
      else return;
      if (!action) return;
      event.preventDefault();
      action();
    };
    window.addEventListener("keydown", navigate);
    return () => window.removeEventListener("keydown", navigate);
  }, [onPrevious, onNext]);

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

  const supportedImage = !!file && (["image/png", "image/jpeg", "image/webp", "image/gif", "image/avif"].includes(file.contentType)
    || (file.contentType === "image/tiff" && !!file.variants?.thumb_1568));
  let preview: ReactNode = null;
  if (file) {
    if (!supportedImage) {
      preview = <p className="m-auto p-6 text-sm text-zinc-200">{uiText("Download this file to view its contents.", "ダウンロードしてファイルの内容を確認してください。")}</p>;
    } else if (failed) {
      preview = <p className="m-auto p-6 text-sm text-red-200" role="alert">
        {uiText("Unable to load preview.", "プレビューを読み込めません。")} <button className="underline" onClick={() => { setFailed(false); query.reload(); }}>{uiText("Retry", "再試行")}</button>
      </p>;
    } else {
      preview = <img ref={previewImage} className="block size-full rounded-lg object-contain" src={file.variants?.thumb_1568 ?? content} alt={file.metadata.caption || file.name} onError={() => setFailed(true)} onClick={closeOnBackdropClick} />;
    }
  }

  const infoLabel = uiText("Image information", "画像情報");
  const copyLabel = uiText("Copy image", "画像をコピー");
  const downloadLabel = uiText("Download", "ダウンロード");
  const actionClass = "grid size-11 place-items-center rounded-full bg-white text-zinc-900 shadow-lg outline-none hover:bg-zinc-100 focus-visible:ring-3 focus-visible:ring-blue-300 disabled:cursor-default disabled:opacity-50";
  const navigationClass = "absolute top-1/2 z-10 grid size-11 -translate-y-1/2 place-items-center rounded-full bg-white text-3xl leading-none text-zinc-900 shadow-lg outline-none hover:bg-zinc-100 focus-visible:ring-3 focus-visible:ring-blue-300 disabled:cursor-default disabled:opacity-35";
  return <section className={`relative grid h-full min-h-75 grid-cols-1 grid-rows-[64px_minmax(0,1fr)_64px] gap-3 bg-zinc-800 p-3 text-white sm:px-6${infoOpen && file ? " lg:grid-cols-[minmax(0,1fr)_320px]" : ""}`} aria-label={uiText("File preview", "ファイルプレビュー")}
    onClick={closeOnBackdropClick}>
    <header className="col-span-full flex items-start justify-end gap-2" onClick={closeOnBackdropClick}>
      <Tooltip label={infoLabel}><button className={actionClass} aria-label={infoLabel} aria-expanded={infoOpen} onClick={() => setInfoOpen(!infoOpen)} disabled={!file}><ViewerIcon path="M12 8h.01M11 11h1v6h1M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z" /></button></Tooltip>
      <Tooltip label={copyLabel}><button className={actionClass} aria-label={copyLabel} disabled={!supportedImage || failed} onClick={() => void copyImage()}><ViewerIcon path="M9 3h10v14H9zM9 7H5v14h10v-4" /></button></Tooltip>
      {file && <Tooltip label={downloadLabel}><a className={actionClass} aria-label={downloadLabel} href={content} download={file.name}><ViewerIcon path="M12 3v13m-5-5 5 5 5-5M5 20h14" /></a></Tooltip>}
      {onClose && <Tooltip label={uiText("Close", "閉じる")}><button autoFocus className={actionClass} aria-label={uiText("Close", "閉じる")} onClick={onClose}><ViewerIcon path="m6 6 12 12M18 6 6 18" /></button></Tooltip>}
    </header>
    <div className="relative col-start-1 row-start-2 flex min-h-0 min-w-0 overflow-auto" onClick={closeOnBackdropClick}>
      {query.error && <p className="absolute inset-x-0 top-0 z-10 bg-zinc-800 p-6 text-sm text-red-200" role="alert">{uiText("Unable to load this file. It may have been deleted or access has changed.", "ファイルを読み込めません。削除されたか、アクセス権が変更された可能性があります。")} <button className="underline" onClick={query.reload}>{uiText("Retry", "再試行")}</button></p>}
      {!file && !query.error && <p className="m-auto text-sm text-zinc-300">{uiText("Loading…", "読み込み中…")}</p>}
      {file && <div className="m-auto shrink-0" style={{ width: `${zoom}%`, height: `${zoom}%` }}>{preview}</div>}
    </div>
    {(onPrevious || onNext) && <>
      <button className={`${navigationClass} left-2 sm:left-6`} aria-label={uiText("Previous image", "前の画像")} disabled={!onPrevious} onClick={onPrevious}>‹</button>
      <button className={`${navigationClass} right-2 sm:right-6${infoOpen && file ? " lg:right-[356px]" : ""}`} aria-label={uiText("Next image", "次の画像")} disabled={!onNext} onClick={onNext}>›</button>
    </>}
    {infoOpen && file && <aside className="col-start-1 row-start-2 z-10 min-h-0 w-[min(320px,85%)] justify-self-end overflow-auto rounded-xl border bg-white p-4 text-[13px] leading-5 text-zinc-900 shadow-xl lg:col-start-2 lg:w-auto lg:shadow-none" aria-label={infoLabel}>
      <h2 className="mb-3 font-semibold">{infoLabel}</h2>
      <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-2.5 gap-y-1.5 [&_dd]:m-0">
        {capturedAt && <><dt>{uiText("Captured", "撮影日時")}</dt><dd>{new Date(capturedAt).toLocaleString()}</dd></>}
        <dt>{uiText("File format", "ファイル形式")}</dt><dd>{file.contentType}</dd>
        {file.size !== undefined && <><dt>{uiText("File size", "ファイルサイズ")}</dt><dd>{new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(file.size / 1024)} kB</dd></>}
        {file.metadata.width && file.metadata.height && <><dt>{uiText("Image size", "画像サイズ")}</dt><dd>{file.metadata.width} × {file.metadata.height}</dd></>}
      </dl>
      <h2 className="mb-3 mt-4 border-t pt-3.5 font-semibold">{uiText("Image description", "画像の説明")}</h2><p className="whitespace-pre-wrap">{file.metadata.caption || uiText("No description", "説明はありません")}</p>
      <h2 className="mb-3 mt-4 border-t pt-3.5 font-semibold">{uiText("Detected text", "検出したテキスト")}</h2><p className="whitespace-pre-wrap">{file.metadata.ocrText || uiText("No detected text", "検出したテキストはありません")}</p>
      <p className="my-4 text-zinc-500">{file.name}</p>
      {separateTab && <a className="text-primary hover:underline" href={`/files/${fileId}`} target="_blank" rel="noreferrer">{uiText("Open in new tab", "別タブで開く")}</a>}
    </aside>}
    <footer className="col-span-full row-start-3 flex self-center justify-self-center rounded-full bg-white p-1 text-zinc-900 shadow-lg [&_button]:h-9 [&_button]:min-w-9 [&_button]:rounded-full [&_button]:px-2 [&_button]:text-sm [&_button]:tabular-nums [&_button]:hover:bg-zinc-100 [&_button]:disabled:opacity-35" aria-label={uiText("Zoom", "ズーム")}>
      <button aria-label={uiText("Zoom out", "縮小")} disabled={!supportedImage || zoom <= 25} onClick={() => setZoom(Math.max(25, zoom - 25))}>−</button>
      <button title={uiText("Fit to view", "画面に合わせる")} onClick={() => setZoom(100)}>{zoom}%</button>
      <button aria-label={uiText("Zoom in", "拡大")} disabled={!supportedImage || zoom >= 400} onClick={() => setZoom(Math.min(400, zoom + 25))}>+</button>
    </footer>
    {copyStatus && <p className="absolute bottom-18 left-1/2 max-w-[90%] -translate-x-1/2 rounded-lg bg-white px-4 py-2.5 text-sm text-zinc-900" role="status">{copyStatus}</p>}
  </section>;
}

export function FileDialog({ fileId, capturedAt, onClose, onPrevious, onNext, returnFocus }: {
  fileId: string;
  capturedAt?: string | null;
  onClose: () => void;
  onPrevious?: () => void;
  onNext?: () => void;
  returnFocus?: HTMLElement | null;
}) {
  return <Dialog open onOpenChange={(value) => { if (!value) onClose(); }}>
    <DialogContent showCloseButton={false} className="h-dvh max-h-dvh w-screen max-w-none rounded-none border-0 bg-zinc-900 p-0" aria-label={uiText("File preview", "ファイルプレビュー")}
      onCloseAutoFocus={(event) => { if (returnFocus) { event.preventDefault(); returnFocus.focus({ preventScroll: true }); } }}>
      <FileViewer fileId={fileId} capturedAt={capturedAt} separateTab onClose={onClose}
        onPrevious={onPrevious} onNext={onNext} />
    </DialogContent>
  </Dialog>;
}

export function FileLink({ fileId, label, children, capturedAt, onOpen }: {
  fileId: string;
  label: string;
  children: ReactNode;
  capturedAt?: string | null;
  onOpen?: (link: HTMLAnchorElement) => void;
}) {
  const link = useRef<HTMLAnchorElement>(null);
  const [open, setOpen] = useState(false);
  return <>
    <a ref={link} href={`/files/${fileId}`} aria-label={label} onClick={(event) => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      if (onOpen) onOpen(event.currentTarget);
      else setOpen(true);
    }}>{children}</a>
    {open && <FileDialog fileId={fileId} capturedAt={capturedAt} returnFocus={link.current} onClose={() => setOpen(false)} />}
  </>;
}

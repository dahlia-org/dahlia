import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { createPortal } from "react-dom";
import type { SearchHit, SearchResults } from "../search/model";
import { json, uiText, type SyncedProjectInfo } from "./api";
import { useLiveJSON, useLiveQuery } from "./live-data";
import { navigateDashboard } from "./navigation";
import { FileViewer } from "./FileViewer";

export function searchDate(value: string, end = false): string | undefined {
  if (!value) return undefined;
  const date = new Date(`${value}T00:00:00`);
  if (end) date.setDate(date.getDate() + 1);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString();
}

export function Search({ vaultId }: { vaultId: string }) {
  const [open, setOpen] = useState(false);
  useEffect(() => {
    const key = (event: globalThis.KeyboardEvent) => {
      if (!event.isComposing && (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault(); setOpen((value) => !value);
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, []);
  return <>
    <button className="sidebar-search secondary" onClick={() => setOpen(true)}>{uiText("Search", "検索")} <kbd>⌘K / Ctrl K</kbd></button>
    {open && createPortal(<SearchDialog vaultId={vaultId} onClose={() => setOpen(false)} />, document.body)}
  </>;
}

function SearchDialog({ vaultId, onClose }: { vaultId: string; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [previousFocus] = useState(() => document.activeElement);
  const [text, setText] = useState("");
  const [query, setQuery] = useState("");
  const [composing, setComposing] = useState(false);
  const [advanced, setAdvanced] = useState(false);
  const [projectId, setProjectId] = useState("");
  const [kind, setKind] = useState("");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [selected, setSelected] = useState(0);
  const [visible, setVisible] = useState(6);
  const [preview, setPreview] = useState<SearchHit>();
  const projects = useLiveJSON<{ items: SyncedProjectInfo[] }>(`/api/v1/vaults/${vaultId}/projects`);
  useEffect(() => {
    const element = dialog.current;
    element?.showModal();
    return () => { element?.close(); if (previousFocus instanceof HTMLElement) previousFocus.focus(); };
  }, [previousFocus]);
  useEffect(() => {
    if (composing) return;
    const timer = setTimeout(() => { setQuery(text); setSelected(0); setVisible(text.trim() ? 20 : 6); }, 300);
    return () => clearTimeout(timer);
  }, [text, composing]);
  const body = JSON.stringify({ vaultId, query, kind: kind || undefined, projectId: projectId || undefined,
    from: searchDate(from), to: searchDate(to, true), limit: 100 });
  const current = !composing && query === text;
  const results = useLiveQuery<SearchResults>(current ? body : undefined, (signal) =>
    json("/api/v1/search", { method: "POST", body, signal }, { notifyMutation: false }));
  const groups = [
    { title: query ? uiText("Meetings", "ミーティング") : uiText("Recent meetings", "最近のミーティング"), items: results.data?.meetings ?? [] },
    { title: uiText("Screenshots", "スクリーンショット"), items: results.data?.screenshots ?? [] },
    { title: query ? uiText("Projects", "プロジェクト") : uiText("Recently active projects", "最近動いたプロジェクト"), items: results.data?.projects ?? [] },
  ];
  const hits = groups.flatMap((group) => group.items.slice(0, visible));
  const active = Math.min(selected, Math.max(0, hits.length - 1));
  function activate(hit?: SearchHit) {
    if (!hit) return;
    if (hit.kind === "screenshot") { setPreview(hit); return; }
    onClose();
    navigateDashboard(hit.kind === "project" ? `/projects/${hit.id}` : `/meetings/${hit.id}`);
  }
  function keyDown(event: KeyboardEvent<HTMLDialogElement>) {
    if (event.nativeEvent.isComposing || composing || preview) return;
    if ((event.metaKey || event.ctrlKey) && /^[1-9]$/.test(event.key)) {
      event.preventDefault(); activate(hits[Number(event.key) - 1]);
    } else if (event.target instanceof HTMLInputElement && event.target.type === "search") {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault(); setSelected(Math.max(0, Math.min(hits.length - 1, active + (event.key === "ArrowDown" ? 1 : -1))));
      } else if (event.key === "Enter") { event.preventDefault(); activate(hits[active]); }
    }
  }
  useEffect(() => { dialog.current?.querySelector('[data-selected="true"]')?.scrollIntoView({ block: "nearest" }); }, [active]);
  let index = 0;
  return <dialog ref={dialog} className={`search-dialog${preview ? " search-preview" : ""}`} aria-label={uiText("Search", "検索")}
    onKeyDown={keyDown} onCancel={(event) => { event.preventDefault(); if (preview) setPreview(undefined); else onClose(); }}
    onClick={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    {preview?.fileId ? <FileViewer fileId={preview.fileId} capturedAt={preview.date} onClose={() => setPreview(undefined)} /> : <>
      <div className="search-toolbar">
        <input autoFocus type="search" value={text} maxLength={500} aria-label={uiText("Search meetings, screenshots and projects", "ミーティング、スクリーンショット、プロジェクトを検索")}
          placeholder={uiText("Search meetings, screenshots and projects", "ミーティング、スクリーンショット、プロジェクトを検索")}
          onCompositionStart={() => setComposing(true)} onCompositionEnd={() => setComposing(false)} onChange={(event) => setText(event.target.value)} />
        <button className="secondary" aria-expanded={advanced} onClick={() => setAdvanced(!advanced)}>{uiText("Advanced", "絞り込み")}</button>
        <button className="secondary" aria-label={uiText("Close", "閉じる")} onClick={onClose}>×</button>
      </div>
      {advanced && <div className="search-filters">
        <label>{uiText("Project", "プロジェクト")}<select value={projectId} onChange={(event) => { setProjectId(event.target.value); setSelected(0); }}>
          <option value="">{uiText("All projects", "すべて")}</option>
          {projects.data?.items.map((project) => <option key={project.projectId} value={project.projectId}>{project.path}</option>)}
        </select></label>
        <label>{uiText("Type", "種類")}<select value={kind} onChange={(event) => { setKind(event.target.value); setSelected(0); }}>
          <option value="">{uiText("All types", "すべて")}</option><option value="meeting">{uiText("Meetings", "ミーティング")}</option>
          <option value="screenshot">{uiText("Screenshots", "スクリーンショット")}</option><option value="project">{uiText("Projects", "プロジェクト")}</option>
        </select></label>
        <label>{uiText("From", "開始日")}<input type="date" value={from} max={to || undefined} onChange={(event) => setFrom(event.target.value)} /></label>
        <label>{uiText("Through", "終了日")}<input type="date" value={to} min={from || undefined} onChange={(event) => setTo(event.target.value)} /></label>
        {projects.error && <button onClick={projects.reload}>{uiText("Retry projects", "プロジェクトを再読み込み")}</button>}
      </div>}
      <div className="search-results" aria-busy={results.loading || !current}>
        {(results.loading || !current) && <p role="status">{uiText("Searching…", "検索中…")}</p>}
        {results.error && <p role="alert">{uiText("Search failed.", "検索に失敗しました。 ")} <button onClick={results.reload}>{uiText("Retry", "再試行")}</button></p>}
        {!results.loading && current && !results.error && !hits.length && <p role="status">{uiText("No results", "該当する項目はありません")}</p>}
        {groups.filter((group) => group.items.length).map((group) => <section key={group.title}>
          <h2>{group.title}</h2>
          {group.items.slice(0, visible).map((hit) => {
            const position = index++;
            return <button key={hit.id} className="search-result" data-selected={position === active} onClick={() => activate(hit)}>
              {hit.fileId && <img src={`/api/v1/files/${hit.fileId}/variants/thumb_480`} alt="" loading="lazy"
                onError={(event) => { const image = event.currentTarget; const original = `/api/v1/files/${hit.fileId}`; if (image.getAttribute("src") !== original) image.src = original; }} />}
              <span className="search-result-copy"><strong>{hit.title}</strong><small>{hit.projectPath}{hit.meetingCount !== undefined ? ` · ${hit.meetingCount} ${uiText("meetings", "件のミーティング")}` : ""}</small>
                {hit.snippet && <span>{hit.snippet}</span>}</span>
              <time>{new Date(hit.date).toLocaleDateString()}</time>{position < 9 && <kbd>{position + 1}</kbd>}
            </button>;
          })}
        </section>)}
        {groups.some((group) => group.items.length > visible) && <button onClick={() => setVisible(Math.min(100, visible + 20))}>{uiText("Load more", "さらに読み込む")}</button>}
        {results.data && Object.values(results.data.limited).some(Boolean) && <p className="muted">{uiText("Showing top results (up to 100 per type). Refine your search to find more.", "各種類の上位100件までを表示しています。検索語や条件を絞ってください。")}</p>}
      </div>
    </>}
  </dialog>;
}

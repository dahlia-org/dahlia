import { apiUrls } from "./generated-operations";
import { apiOperations as api } from "./generated-operations";
import { apiQuery } from "./live-data";
import { Select } from "./Select";
import { Tooltip } from "./Tooltip";
import { useEffect, useId, useRef, useState, type KeyboardEvent } from "react";
import { createPortal } from "react-dom";
import type { SearchHit, SearchResults } from "../search/model";
import { uiText, type SyncedProjectInfo } from "./api";
import { useLiveJSON, useLiveQuery } from "./live-data";
import { navigateDashboard } from "./navigation";
import { FileViewer } from "./FileViewer";
import { MenuIcon } from "./Sidebar";

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
      if (document.querySelector(".action-dialog:modal, .file-dialog:modal")) return;
      if (!event.isComposing && (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault(); setOpen((value) => !value);
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, []);
  return <>
    <Tooltip className="navigation-search" label={uiText("Search", "検索")} shortcut={/Mac|iPhone|iPad/.test(navigator.platform) ? "⌘ K" : "Ctrl K"}>
    <button className="sidebar-search icon-button" aria-label={uiText("Search", "検索")}
      onClick={() => setOpen(true)}><MenuIcon name="search" /></button>
    </Tooltip>
    {open && createPortal(<SearchDialog vaultId={vaultId} onClose={() => setOpen(false)} />, document.body)}
  </>;
}

function SearchDialog({ vaultId, onClose }: { vaultId: string; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const id = useId();
  const [previousFocus] = useState(() => document.activeElement);
  const [text, setText] = useState("");
  const [query, setQuery] = useState("");
  const [composing, setComposing] = useState(false);
  const [advanced, setAdvanced] = useState(false);
  const [projectId, setProjectId] = useState("");
  const [kind, setKind] = useState<"" | "meeting" | "screenshot" | "project">("");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [selected, setSelected] = useState(0);
  const [visible, setVisible] = useState(6);
  const [preview, setPreview] = useState<SearchHit>();
  const filterCount = [projectId, kind, from, to].filter(Boolean).length;
  const projects = useLiveJSON<{ items: SyncedProjectInfo[] }>(apiQuery("listProjects", { params: { path: { vaultId: vaultId } } }));
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
  const body = { query, kind: kind || undefined, projectId: projectId || undefined,
    from: searchDate(from), to: searchDate(to, true), limit: 100 };
  const current = !composing && query === text;
  const results = useLiveQuery<SearchResults>(current ? JSON.stringify(body) : undefined, (signal) =>
    api.search({ params: { path: { vaultId } }, body, signal }));
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
    onClick={(event) => {
      const rect = event.currentTarget.getBoundingClientRect();
      if (event.target === event.currentTarget && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) onClose();
    }}>
    {preview?.fileId ? <FileViewer fileId={preview.fileId} capturedAt={preview.date} onClose={() => setPreview(undefined)} /> : <>
      <div className="search-toolbar">
        <input autoFocus type="search" value={text} maxLength={500} role="combobox" aria-autocomplete="list" aria-expanded="true"
          aria-controls={`${id}-results`} aria-activedescendant={hits.length ? `${id}-result-${active}` : undefined}
          aria-label={uiText("Search meetings, screenshots and projects", "ミーティング、スクリーンショット、プロジェクトを検索")}
          placeholder={uiText("Search meetings, screenshots and projects", "ミーティング、スクリーンショット、プロジェクトを検索")}
          onCompositionStart={() => setComposing(true)} onCompositionEnd={() => setComposing(false)} onChange={(event) => setText(event.target.value)} />
        <button className="secondary" aria-expanded={advanced} aria-controls={`${id}-filters`} onClick={() => setAdvanced(!advanced)}>{uiText("Filters", "絞り込み")}{filterCount > 0 && ` (${filterCount})`}</button>
        <button className="icon-button" aria-label={uiText("Close", "閉じる")} onClick={onClose}>×</button>
      </div>
      {advanced && <div className="search-filters" id={`${id}-filters`}>
        <label>{uiText("Project", "プロジェクト")}<Select value={projectId} onValueChange={(value) => { setProjectId(value); setSelected(0); }}>
          <option value="">{uiText("All projects", "すべて")}</option>
          {projects.data?.items.map((project) => <option key={project.projectId} value={project.projectId}>{project.path}</option>)}
        </Select></label>
        <label>{uiText("Type", "種類")}<Select value={kind} onValueChange={(value) => { if (value === "" || value === "meeting" || value === "screenshot" || value === "project") setKind(value); setSelected(0); }}>
          <option value="">{uiText("All types", "すべて")}</option><option value="meeting">{uiText("Meetings", "ミーティング")}</option>
          <option value="screenshot">{uiText("Screenshots", "スクリーンショット")}</option><option value="project">{uiText("Projects", "プロジェクト")}</option>
        </Select></label>
        <label>{uiText("From", "開始日")}<input type="date" value={from} max={to || undefined} onChange={(event) => setFrom(event.target.value)} /></label>
        <label>{uiText("Through", "終了日")}<input type="date" value={to} min={from || undefined} onChange={(event) => setTo(event.target.value)} /></label>
        {filterCount > 0 && <button className="secondary" onClick={() => { setProjectId(""); setKind(""); setFrom(""); setTo(""); setSelected(0); }}>{uiText("Clear filters", "絞り込みを解除")}</button>}
        {projects.error && <button className="secondary" onClick={projects.reload}>{uiText("Retry projects", "プロジェクトを再読み込み")}</button>}
      </div>}
      <div className="search-results" aria-busy={results.loading || !current}>
        {(results.loading || !current) && <p role="status">{uiText("Searching…", "検索中…")}</p>}
        {results.error && <p role="alert">{uiText("Search failed.", "検索に失敗しました。 ")} <button className="secondary" onClick={results.reload}>{uiText("Retry", "再試行")}</button></p>}
        {!results.loading && current && !results.error && !hits.length && <div className="welcome-empty compact-empty" role="status"><h2>{uiText("No results", "該当する項目はありません")}</h2><p>{uiText("Try another word or broaden your filters. Search includes meeting content, image text and projects in this Vault.", "検索語や絞り込み条件を変えてみてください。この保管庫のミーティング本文、画像内の文字、プロジェクトを検索します。")}</p></div>}
        <div id={`${id}-results`} role="listbox" aria-label={uiText("Search results", "検索結果")}>
        {groups.filter((group) => group.items.length).map((group) => <section key={group.title} role="group" aria-label={group.title}>
          <h2>{group.title}</h2>
          {group.items.slice(0, visible).map((hit) => {
            const position = index++;
            return <button key={hit.id} className="search-result" id={`${id}-result-${position}`} role="option" aria-selected={position === active} data-selected={position === active} onClick={() => activate(hit)}>
              {hit.fileId && <img src={apiUrls.getFileVariant({ params: { path: { fileId: hit.fileId, variant: "thumb_480" } } })} alt="" loading="lazy"
                onError={(event) => { const image = event.currentTarget; const original = apiUrls.getFileContent({ params: { path: { fileId: hit.fileId! } } }); if (image.getAttribute("src") !== original) image.src = original; }} />}
              <span className="search-result-copy"><strong>{hit.title}</strong><small>{hit.projectPath}{hit.meetingCount !== undefined ? ` · ${hit.meetingCount} ${uiText("meetings", "件のミーティング")}` : ""}</small>
                {hit.snippet && <span>{hit.snippet}</span>}</span>
              <time>{new Date(hit.date).toLocaleDateString()}</time>{position < 9 && <kbd>{position + 1}</kbd>}
            </button>;
          })}
        </section>)}
        </div>
        {groups.some((group) => group.items.length > visible) && <button className="secondary load-more" onClick={() => setVisible(Math.min(100, visible + 20))}>{uiText("Load more", "さらに読み込む")}</button>}
        {results.data && Object.values(results.data.limited).some(Boolean) && <p className="muted">{uiText("Showing top results (up to 100 per type). Refine your search to find more.", "各種類の上位100件までを表示しています。検索語や条件を絞ってください。")}</p>}
      </div>
      <footer className="search-footer"><span><kbd>↑</kbd> <kbd>↓</kbd> {uiText("Navigate", "選択")}</span><span><kbd>↵</kbd> {uiText("Open", "開く")}</span><span><kbd>esc</kbd> {uiText("Close", "閉じる")}</span><span>{uiText("Search within this Vault", "この保管庫内を検索")}</span></footer>
    </>}
  </dialog>;
}

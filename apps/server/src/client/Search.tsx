import { apiUrls } from "./generated-operations";
import { apiOperations as api } from "./generated-operations";
import { apiQuery } from "./live-data";
import { Select } from "./Select";
import { Tooltip } from "./Tooltip";
import { useCallback, useEffect, useId, useRef, useState, type KeyboardEvent } from "react";
import type { SearchHit, SearchResults } from "../search/model";
import { uiText, type SyncedProjectInfo } from "./api";
import { useLiveJSON, useLiveQuery } from "./live-data";
import { navigateDashboard } from "./navigation";
import { FileViewer } from "./FileViewer";
import { MenuIcon } from "./Sidebar";
import { Button } from "./components/ui/button";
import { Dialog, DialogContent } from "./components/ui/dialog";
import { Input } from "./components/ui/input";

export function searchDate(value: string, end = false): string | undefined {
  if (!value) return undefined;
  const date = new Date(`${value}T00:00:00`);
  if (end) date.setDate(date.getDate() + 1);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString();
}

export function Search({ workspaceId }: { workspaceId: string }) {
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  const close = useCallback(() => { setOpen(false); requestAnimationFrame(() => trigger.current?.focus()); }, []);
  useEffect(() => {
    const key = (event: globalThis.KeyboardEvent) => {
      if (!open && document.querySelector('[data-slot="dialog-content"]')) return;
      if (!event.isComposing && (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        if (open) close(); else setOpen(true);
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [close, open]);
  return <>
    <Tooltip className="navigation-search ml-auto shrink-0" label={uiText("Search", "検索")} shortcut={/Mac|iPhone|iPad/.test(navigator.platform) ? "⌘ K" : "Ctrl K"}>
    <Button ref={trigger} variant="ghost" size="icon" aria-label={uiText("Search", "検索")}
      onClick={() => setOpen(true)}><MenuIcon name="search" /></Button>
    </Tooltip>
    {open && <SearchDialog workspaceId={workspaceId} onClose={close} />}
  </>;
}

function SearchDialog({ workspaceId, onClose }: { workspaceId: string; onClose: () => void }) {
  const id = useId();
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
  const projects = useLiveJSON<{ items: SyncedProjectInfo[] }>(apiQuery("listProjects", { params: { path: { workspaceId: workspaceId } } }));
  useEffect(() => {
    if (composing) return;
    const timer = setTimeout(() => { setQuery(text); setSelected(0); setVisible(text.trim() ? 20 : 6); }, 300);
    return () => clearTimeout(timer);
  }, [text, composing]);
  const body = { query, kind: kind || undefined, projectId: projectId || undefined,
    from: searchDate(from), to: searchDate(to, true), limit: 100 };
  const current = !composing && query === text;
  const results = useLiveQuery<SearchResults>(current ? JSON.stringify(body) : undefined, (signal) =>
    api.search({ params: { path: { workspaceId } }, body, signal }));
  const groups = [
    { title: query ? uiText("Meetings", "ミーティング") : uiText("Recent meetings", "最近のミーティング"), items: results.data?.meetings ?? [] },
    { title: uiText("Screenshots", "スクリーンショット"), items: results.data?.screenshots ?? [] },
    { title: query ? uiText("Projects", "プロジェクト") : uiText("Recently active projects", "最近動いたプロジェクト"), items: results.data?.projects ?? [] },
  ];
  const hits = groups.flatMap((group) => group.items.slice(0, visible));
  const screenshotHits = (results.data?.screenshots ?? []).slice(0, visible).filter((hit) => hit.fileId);
  const previewIndex = preview ? screenshotHits.findIndex((hit) => hit.id === preview.id) : -1;
  const active = Math.min(selected, Math.max(0, hits.length - 1));
  function activate(hit?: SearchHit) {
    if (!hit) return;
    if (hit.kind === "screenshot") { setPreview(hit); return; }
    onClose();
    navigateDashboard(hit.kind === "project" ? `/projects/${hit.id}` : `/meetings/${hit.id}`);
  }
  function keyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.nativeEvent.isComposing || composing || preview) return;
    if ((event.metaKey || event.ctrlKey) && /^[1-9]$/.test(event.key)) {
      event.preventDefault(); activate(hits[Number(event.key) - 1]);
    } else if (event.target instanceof HTMLInputElement && event.target.type === "search") {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault(); setSelected(Math.max(0, Math.min(hits.length - 1, active + (event.key === "ArrowDown" ? 1 : -1))));
      } else if (event.key === "Enter") { event.preventDefault(); activate(hits[active]); }
    }
  }
  useEffect(() => { document.getElementById(`${id}-result-${active}`)?.scrollIntoView({ block: "nearest" }); }, [active, id]);
  let index = 0;
  return <Dialog open onOpenChange={(value) => { if (!value) onClose(); }}>
    <DialogContent showCloseButton={!preview} aria-label={uiText("Search", "検索")} className={preview
      ? "h-dvh max-h-dvh w-screen max-w-none rounded-none border-0 bg-zinc-900 p-0"
      : "top-[8vh] max-h-[84dvh] max-w-3xl translate-y-0 gap-0 overflow-hidden p-0"}
      onKeyDown={keyDown} onEscapeKeyDown={(event) => { if (preview) { event.preventDefault(); setPreview(undefined); } }}>
    {preview?.fileId ? <div className="h-full"><FileViewer fileId={preview.fileId} capturedAt={preview.date} separateTab
      onClose={() => setPreview(undefined)}
      onPrevious={previewIndex > 0 ? () => setPreview(screenshotHits[previewIndex - 1]) : undefined}
      onNext={previewIndex >= 0 && previewIndex < screenshotHits.length - 1 ? () => setPreview(screenshotHits[previewIndex + 1]) : undefined} /></div> : <>
      <div className="flex items-center gap-2 border-b p-3 pr-11">
        <Input autoFocus className="h-10 flex-1 border-0 bg-transparent text-base shadow-none focus-visible:ring-0" type="search" value={text} maxLength={500} role="combobox" aria-autocomplete="list" aria-expanded="true"
          aria-controls={`${id}-results`} aria-activedescendant={hits.length ? `${id}-result-${active}` : undefined}
          aria-label={uiText("Search meetings, screenshots and projects", "ミーティング、スクリーンショット、プロジェクトを検索")}
          placeholder={uiText("Search meetings, screenshots and projects", "ミーティング、スクリーンショット、プロジェクトを検索")}
          onCompositionStart={() => setComposing(true)} onCompositionEnd={() => setComposing(false)} onChange={(event) => setText(event.target.value)} />
        <Button variant="outline" size="sm" aria-expanded={advanced} aria-controls={`${id}-filters`} onClick={() => setAdvanced(!advanced)}>{uiText("Filters", "絞り込み")}{filterCount > 0 && ` (${filterCount})`}</Button>
      </div>
      {advanced && <div className="grid grid-cols-2 gap-3 border-b bg-muted/40 p-4 sm:grid-cols-4" id={`${id}-filters`}>
        <label className="grid gap-1.5 text-xs text-muted-foreground">{uiText("Project", "プロジェクト")}<Select value={projectId} onValueChange={(value) => { setProjectId(value); setSelected(0); }}>
          <option value="">{uiText("All projects", "すべて")}</option>
          {projects.data?.items.map((project) => <option key={project.projectId} value={project.projectId}>{project.path}</option>)}
        </Select></label>
        <label className="grid gap-1.5 text-xs text-muted-foreground">{uiText("Type", "種類")}<Select value={kind} onValueChange={(value) => { if (value === "" || value === "meeting" || value === "screenshot" || value === "project") setKind(value); setSelected(0); }}>
          <option value="">{uiText("All types", "すべて")}</option><option value="meeting">{uiText("Meetings", "ミーティング")}</option>
          <option value="screenshot">{uiText("Screenshots", "スクリーンショット")}</option><option value="project">{uiText("Projects", "プロジェクト")}</option>
        </Select></label>
        <label className="grid gap-1.5 text-xs text-muted-foreground">{uiText("From", "開始日")}<Input type="date" value={from} max={to || undefined} onChange={(event) => setFrom(event.target.value)} /></label>
        <label className="grid gap-1.5 text-xs text-muted-foreground">{uiText("Through", "終了日")}<Input type="date" value={to} min={from || undefined} onChange={(event) => setTo(event.target.value)} /></label>
        {filterCount > 0 && <Button variant="outline" size="sm" onClick={() => { setProjectId(""); setKind(""); setFrom(""); setTo(""); setSelected(0); }}>{uiText("Clear filters", "絞り込みを解除")}</Button>}
        {projects.error && <Button variant="outline" size="sm" onClick={projects.reload}>{uiText("Retry projects", "プロジェクトを再読み込み")}</Button>}
      </div>}
      <div data-slot="search-results-scroll" className="min-h-64 flex-1 overflow-y-auto p-3" aria-busy={results.loading || !current}>
        {(results.loading || !current) && <p className="p-4 text-sm text-muted-foreground" role="status">{uiText("Searching…", "検索中…")}</p>}
        {results.error && <p className="p-4 text-sm text-destructive" role="alert">{uiText("Search failed.", "検索に失敗しました。 ")} <Button variant="outline" size="sm" onClick={results.reload}>{uiText("Retry", "再試行")}</Button></p>}
        {!results.loading && current && !results.error && !hits.length && <div className="grid min-h-56 place-content-center gap-2 text-center" role="status"><h2 className="font-semibold">{uiText("No results", "該当する項目はありません")}</h2><p className="max-w-lg text-sm text-muted-foreground">{uiText("Try another word or broaden your filters. Search includes meeting content, image text and projects in this Workspace.", "検索語や絞り込み条件を変えてみてください。このワークスペースのミーティング本文、画像内の文字、プロジェクトを検索します。")}</p></div>}
        <div id={`${id}-results`} role="listbox" aria-label={uiText("Search results", "検索結果")}>
        {groups.filter((group) => group.items.length).map((group) => <section className="mb-3" key={group.title} role="group" aria-label={group.title}>
          <h2 className="px-2 py-1.5 text-xs font-semibold text-muted-foreground">{group.title}</h2>
          {group.items.slice(0, visible).map((hit) => {
            const position = index++;
            return <button key={hit.id} className="grid w-full grid-cols-[minmax(0,1fr)_auto] items-center gap-3 rounded-lg px-2 py-2 text-left outline-none hover:bg-accent aria-selected:bg-accent aria-selected:text-accent-foreground has-[img]:grid-cols-[80px_minmax(0,1fr)_auto]" id={`${id}-result-${position}`} role="option" aria-selected={position === active} data-selected={position === active} onClick={() => activate(hit)}>
              {hit.fileId && <img className="h-14 w-20 rounded-md object-cover" src={apiUrls.getFileVariant({ params: { path: { fileId: hit.fileId, variant: "thumb_480" } } })} alt="" loading="lazy"
                onError={(event) => { const image = event.currentTarget; const original = apiUrls.getFileContent({ params: { path: { fileId: hit.fileId! } } }); if (image.getAttribute("src") !== original) image.src = original; }} />}
              <span className="grid min-w-0 gap-0.5"><strong className="truncate text-sm font-medium">{hit.title}</strong><small className="truncate text-xs text-muted-foreground">{hit.projectPath}{hit.meetingCount !== undefined ? ` · ${hit.meetingCount} ${uiText("meetings", "件のミーティング")}` : ""}</small>
                {hit.snippet && <span className="line-clamp-2 text-xs text-muted-foreground">{hit.snippet}</span>}</span>
              <span className="flex items-center gap-2 text-xs text-muted-foreground"><time>{new Date(hit.date).toLocaleDateString()}</time>{position < 9 && <kbd className="rounded border bg-background px-1.5 py-0.5">{position + 1}</kbd>}</span>
            </button>;
          })}
        </section>)}
        </div>
        {groups.some((group) => group.items.length > visible) && <Button variant="outline" size="sm" className="mx-auto flex" onClick={() => setVisible(Math.min(100, visible + 20))}>{uiText("Load more", "さらに読み込む")}</Button>}
        {results.data && Object.values(results.data.limited).some(Boolean) && <p className="p-2 text-xs text-muted-foreground">{uiText("Showing top results (up to 100 per type). Refine your search to find more.", "各種類の上位100件までを表示しています。検索語や条件を絞ってください。")}</p>}
      </div>
      <footer className="flex items-center gap-4 border-t px-4 py-2 text-[11px] text-muted-foreground max-sm:hidden"><span><kbd>↑</kbd> <kbd>↓</kbd> {uiText("Navigate", "選択")}</span><span><kbd>↵</kbd> {uiText("Open", "開く")}</span><span><kbd>esc</kbd> {uiText("Close", "閉じる")}</span><span className="ml-auto">{uiText("Search within this Workspace", "このワークスペース内を検索")}</span></footer>
    </>}
  </DialogContent></Dialog>;
}

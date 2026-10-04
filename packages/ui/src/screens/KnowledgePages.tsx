import { useEffect, useEffectEvent, useState } from "react";
import type { components } from "../api/generated-api";

type KnowledgePage = components["schemas"]["KnowledgePage"];
type PageStatus = KnowledgePage["status"];
import { json, uiText, type SyncedProjectInfo } from "../api/api";
import { useLiveQuery } from "../api/live-data";
import { Button } from "../components/ui/button";
import { Input } from "../components/ui/input";

const statusLabel = (status: PageStatus) => ({
  ready: uiText("Ready", "公開可能"), generating: uiText("Generating / validating", "生成・検証中"),
  stale: uiText("Outdated · awaiting validation", "古い版 · 再検証待ち"), source_invalid: uiText("Sources invalidated", "根拠が失効"),
  paused: uiText("Analysis paused", "分析停止中"), unavailable: uiText("Analysis not configured", "分析未設定"),
  error: uiText("Processing failed", "処理失敗"), no_sources: uiText("No sources", "根拠なし"),
}[status]);
export function KnowledgePages({ workspaceId }: { workspaceId: string }) {
  const base = `/api/v1/workspaces/${workspaceId}/memory/pages`;
  const [query, setQuery] = useState(""), [search, setSearch] = useState(""), [projectId, setProjectId] = useState("");
  const [after, setAfter] = useState(""), [selected, setSelected] = useState("");
  const [regenerating, setRegenerating] = useState(false), [actionError, setActionError] = useState(false);
  const params = new URLSearchParams({ ...(search ? { query: search } : {}), ...(projectId ? { projectId } : {}), ...(after ? { after } : {}) });
  const list = useLiveQuery(`${base}?${params}`, (signal) => json<{ items: KnowledgePage[]; nextCursor: string | null }>(`${base}?${params}`, { signal }));
  const detail = useLiveQuery(selected ? `${base}/${selected}` : undefined, (signal) => json<KnowledgePage>(`${base}/${selected}`, { signal }));
  const projects = useLiveQuery(`page-projects:${workspaceId}`, (signal) => json<{ items: SyncedProjectInfo[] }>(`/api/v1/workspaces/${workspaceId}/projects`, { signal }));
  const reload = useEffectEvent(() => { list.reload(); detail.reload(); });
  useEffect(() => {
    const timer = setInterval(() => reload(), 10_000);
    return () => clearInterval(timer);
  }, []);
  // Hide a previously verified response during revalidation or any failed read.
  const page = !list.refreshing && !list.error && !detail.refreshing && !detail.error && !regenerating ? detail.data : undefined;
  const refresh = async () => {
    if (!page) return;
    setRegenerating(true); setActionError(false);
    try { await json(`${base}/${page.id}/refresh`, { method: "POST" }); }
    catch { setActionError(true); }
    finally { list.reload(); detail.reload(); setRegenerating(false); }
  };
  return <section className="workspace-settings grid gap-3" aria-label="Knowledge Pages">
    <h2>Knowledge Pages</h2>
    <p>{uiText("AI-generated summaries and hypotheses. Source checks establish provenance, not truth. Correct the original meeting or saved memory to improve a page.", "AI が生成した要約・仮説です。出典の検証は内容の正しさを保証しません。訂正は元の会議・共有メモを編集してください。")}</p>
    <form className="flex flex-wrap items-end gap-2" onSubmit={(event) => { event.preventDefault(); setSearch(query.trim()); setAfter(""); setSelected(""); }}>
      <label className="grid gap-1">{uiText("Search pages", "ページを検索")}<Input value={query} maxLength={4000} onChange={(event) => setQuery(event.target.value)} /></label>
      <label className="grid gap-1">Project<select className="rounded-md border bg-background p-2" value={projectId} onChange={(event) => { setProjectId(event.target.value); setAfter(""); setSelected(""); }}>
        <option value="">{uiText("All standard pages", "すべての標準ページ")}</option>
        {projects.data?.items.map((project) => <option key={project.projectId} value={project.projectId}>{project.name}</option>)}
      </select></label>
      <Button variant="outline">{uiText("Search", "検索")}</Button>
    </form>
    {(list.error || detail.error || actionError) && <p role="alert">{uiText("Could not verify the page. Retry after checking access and analysis settings.", "ページを検証できません。権限と分析設定を確認して再試行してください。")}</p>}
    <Button variant="outline" onClick={() => { list.reload(); detail.reload(); }}>{uiText("Reload pages", "ページを再読み込み")}</Button>
    {list.refreshing ? <p role="status">{uiText("Validating pages…", "ページを検証中…")}</p> : !list.error && <>
      {!list.data?.items.length && <p>{uiText("No pages in this result.", "この条件に一致するページはありません。")}</p>}
      <ul className="grid gap-2">{list.data?.items.map((item) => <li key={item.id} className="panel">
        <Button variant="link" onClick={() => setSelected(item.id)}>{item.title}</Button> · {statusLabel(item.status)}
        {item.snippet && <p className="whitespace-pre-wrap">{item.snippet}</p>}
      </li>)}</ul>
      <div className="flex gap-2">
        {after && <Button variant="outline" onClick={() => { setAfter(""); setSelected(""); }}>{uiText("First page", "最初へ")}</Button>}
        {list.data?.nextCursor && <Button variant="outline" onClick={() => { setAfter(list.data!.nextCursor!); setSelected(""); }}>{uiText("Next page", "次へ")}</Button>}
      </div>
    </>}
    {selected && (detail.refreshing || regenerating) && <p role="status">{uiText("Validating page…", "ページを検証中…")}</p>}
    {page && <article className="panel grid gap-3">
      <h3>{page.title}</h3><p role="status">{statusLabel(page.status)}</p>
      <p>{page.coverage === "partial" ? uiText(`Partial ingestion: ${page.skippedCount} skipped sources`, `取り込みは一部のみ: ${page.skippedCount} 件を除外`) : page.coverage === "updating" ? uiText("Ingestion updating", "取り込み更新中") : uiText("Ingestion complete", "取り込み完了")}</p>
      {page.generatedAt && <time dateTime={page.generatedAt}>{new Date(page.generatedAt).toLocaleString()}</time>}
      {page.status === "ready" && <>
        <p className="whitespace-pre-wrap break-words">{page.body}</p>
        <a href={`${base}/${page.id}/export`} download>{uiText("Download Markdown", "Markdown をダウンロード")}</a>
        <h4>{uiText("Canonical sources · open to verify or correct", "正本の出典 · 開いて確認・訂正")}</h4>
        <ul className="grid gap-2">{page.sources.map((source) => <li key={source.id}>
          <a href={source.href}>{source.kind === "meeting" ? uiText("Open meeting", "会議を開く") : uiText("Open saved memory", "共有メモを開く")}</a>
          {!!source.imageCoverage?.omitted && <p>{uiText(`${source.imageCoverage.selected} screenshots selected; ${source.imageCoverage.omitted} omitted by selection.`, `画像 ${source.imageCoverage.selected} 枚を選択し、${source.imageCoverage.omitted} 枚を選別で省略しました。`)}</p>}
          <p className="whitespace-pre-wrap">{source.canonicalExcerpt}</p>{source.images?.map((image) => <a key={image.screenshotId} href={image.href} target="_blank" rel="noreferrer">{uiText("Source screenshot", "正本画像")}</a>)}
          {source.truncated && <small>{uiText("Excerpt only", "抜粋のみ")}</small>}
        </li>)}</ul>
      </>}
      {page.canRefresh && !["paused", "unavailable", "generating"].includes(page.status) && <Button variant="outline" disabled={regenerating} onClick={() => void refresh()}>{uiText("Regenerate page", "ページを再生成")}</Button>}
    </article>}
  </section>;
}

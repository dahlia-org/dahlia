import { useEffect, useState, type ReactNode } from "react";
import { uiText } from "./api";
import { Badge } from "./components/ui/badge";
import { Checkbox } from "./components/ui/checkbox";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "./components/ui/tabs";

function record(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null ? value as Record<string, unknown> : {};
}
function list(value: unknown): unknown[] { return Array.isArray(value) ? value : []; }
function text(value: unknown): string { return typeof value === "string" ? value : ""; }

export function parseSummary(document?: string): Record<string, unknown> {
  try { return record(JSON.parse(document ?? "null")); } catch { return {}; }
}

export function SummaryTags({ document }: { document: Record<string, unknown> }) {
  return list(document.tags).filter((tag): tag is string => typeof tag === "string").map((tag, index) =>
    <Badge variant="secondary" key={index}><span className="size-2 rounded-full bg-muted-foreground/70" aria-hidden="true" />{tag}</Badge>);
}

function SummaryText({ value }: { value: unknown }) {
  const content = record(value);
  const reference = text(content.transcript_ref);
  return <>{text(content.text)}{reference && <span className="ml-2 inline-flex rounded-full bg-muted px-2 py-0.5 text-xs text-muted-foreground">{reference}</span>}</>;
}

function SummaryBlock({ value }: { value: unknown }) {
  const block = record(value);
  const content = <SummaryText value={block.content} />;
  switch (block.type) {
    case "bulleted_list":
    case "numbered_list": {
      const List = block.type === "numbered_list" ? "ol" : "ul";
      return <List className={block.type === "numbered_list" ? "my-3 list-decimal space-y-1 pl-6" : "my-3 list-disc space-y-1 pl-6"}>{list(block.items).map((item, index) => <li key={index}><SummaryText value={item} /></li>)}</List>;
    }
    case "checklist":
      return <ul className="my-3 grid list-none gap-2 p-0">{list(block.items).map((value, index) => {
        const item = record(value);
        return <li className="flex items-start gap-2" key={index}>
          <Checkbox checked={item.checked === true} disabled aria-label={text(item.text)} />
          <SummaryText value={item} />
        </li>;
      })}</ul>;
    case "heading": return block.level === 1 ? <h2 className="mb-2 mt-6 text-lg font-semibold">{content}</h2> : <h3 className="mb-2 mt-5 font-semibold">{content}</h3>;
    case "quote": return <blockquote className="my-4 whitespace-pre-wrap border-l-2 border-primary/40 pl-4 text-muted-foreground">{content}</blockquote>;
    case "code": return <pre className="my-4 overflow-x-auto rounded-lg bg-muted p-4 text-sm"><code>{text(record(block.content).text)}</code></pre>;
    case "table": return <div className="my-4 max-w-full overflow-auto rounded-lg border"><table className="w-full border-collapse text-sm">
      <thead><tr>{list(block.headers).map((cell, index) => <th key={index}><SummaryText value={cell} /></th>)}</tr></thead>
      <tbody>{list(block.rows).map((row, index) => <tr key={index}>{list(row).map((cell, column) => <td key={column}><SummaryText value={cell} /></td>)}</tr>)}</tbody>
    </table></div>;
    default: return <p className="my-3 whitespace-pre-wrap">{content}</p>;
  }
}

export function SummaryContent({ document }: { document: Record<string, unknown> }) {
  if (!Array.isArray(document.sections)) return <p className="text-sm text-destructive" role="alert">{uiText("This summary could not be displayed.", "要約を表示できませんでした。")}</p>;
  const description = text(document.description);
  const actionItems = list(document.actionItems);
  return <div className="max-w-none text-[15px] leading-7 text-foreground [&_td]:whitespace-pre-wrap [&_td]:border-b [&_td]:p-3 [&_th]:whitespace-pre-wrap [&_th]:border-b [&_th]:bg-muted/60 [&_th]:p-3 [&_th]:text-left [&_th]:font-medium">
    {description && <p className="my-4 text-muted-foreground">{description}</p>}
    {document.sections.map((value, index) => {
      const section = record(value);
      const heading = text(section.heading);
      return <section key={index}>
        {heading && <h2 className="mb-2 mt-7 text-xl font-semibold tracking-tight first:mt-0">{heading}</h2>}
        {list(section.blocks).map((block, index) => <SummaryBlock key={index} value={block} />)}
      </section>;
    })}
    {actionItems.length > 0 && <section>
      <h2 className="mb-2 mt-7 text-xl font-semibold tracking-tight">{uiText("Action items", "アクションアイテム")}</h2>
      <ul className="my-3 list-disc space-y-1 pl-6">{actionItems.map((value, index) => {
        const item = record(value);
        const assignee = text(item.assignee);
        return <li key={index}>
          {text(item.title)}{assignee && <span className="ml-2 inline-flex rounded-full bg-muted px-2 py-0.5 text-xs text-muted-foreground">{assignee}</span>}
        </li>;
      })}</ul>
    </section>}
  </div>;
}

export function TranscriptTime({ startTime, timeBase }: { startTime: string; timeBase: string }) {
  const seconds = Math.max(0, Math.floor((Date.parse(startTime) - Date.parse(timeBase)) / 1000));
  const timestamp = Number.isFinite(seconds)
    ? [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60].map((part) => String(part).padStart(2, "0")).join(":")
    : "—";
  return <time className="pt-0.5 text-xs tabular-nums text-muted-foreground" dateTime={startTime}>{timestamp}</time>;
}

export function MeetingTabs({ summary, screenshots, transcript, actions }: { summary: ReactNode; screenshots: ReactNode; transcript: ReactNode; actions?: ReactNode }) {
  const tabs = [
    { id: "summary", label: uiText("Summary", "要約"), content: summary },
    { id: "screenshots", label: uiText("Screenshots", "スクリーンショット"), content: screenshots },
    { id: "transcript", label: uiText("Transcript", "文字起こし"), content: transcript },
  ];
  return <DetailTabs tabs={tabs} actions={actions} label={uiText("Meeting content", "ミーティングの内容")} />;
}

export function DetailTabs({ tabs, actions, label }: { tabs: { id: string; label: ReactNode; content: ReactNode }[]; actions?: ReactNode; label: string }) {
  const [selected, setSelected] = useState(tabs[0]?.id);
  const selectedId = tabs.some((tab) => tab.id === selected) ? selected : tabs[0]?.id;
  useEffect(() => {
    if (selected !== selectedId) setSelected((current) => current === selected ? selectedId : current);
  }, [selected, selectedId]);
  return <Tabs value={selectedId} onValueChange={setSelected}>
    <div className="flex items-center justify-between gap-3 border-b">
      <TabsList aria-label={label} className="h-auto rounded-none bg-transparent p-0">
        {tabs.map((tab) => <TabsTrigger key={tab.id} value={tab.id} className="h-10 rounded-none border-b-2 border-transparent bg-transparent px-1.5 shadow-none data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:text-primary data-[state=active]:shadow-none">{tab.label}</TabsTrigger>)}
      </TabsList>
      {actions}
    </div>
    {tabs.map((tab) => <TabsContent key={tab.id} value={tab.id} className="mt-5">{selectedId === tab.id && tab.content}</TabsContent>)}
  </Tabs>;
}

import { useId, useState, type ReactNode } from "react";
import { uiText } from "./api";

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
    <span className="metadata-chip" key={index}><span className="tag-dot" aria-hidden="true" />{tag}</span>);
}

function SummaryText({ value }: { value: unknown }) {
  const content = record(value);
  const reference = text(content.transcript_ref);
  return <>{text(content.text)}{reference && <span className="timestamp">{reference}</span>}</>;
}

function SummaryBlock({ value }: { value: unknown }) {
  const block = record(value);
  const content = <SummaryText value={block.content} />;
  switch (block.type) {
    case "bulleted_list":
    case "numbered_list": {
      const List = block.type === "numbered_list" ? "ol" : "ul";
      return <List>{list(block.items).map((item, index) => <li key={index}><SummaryText value={item} /></li>)}</List>;
    }
    case "checklist":
      return <ul className="summary-checklist">{list(block.items).map((value, index) => {
        const item = record(value);
        return <li key={index}>
          <input type="checkbox" checked={item.checked === true} disabled aria-label={text(item.text)} />
          <SummaryText value={item} />
        </li>;
      })}</ul>;
    case "heading": return block.level === 1 ? <h2>{content}</h2> : <h3>{content}</h3>;
    case "quote": return <blockquote>{content}</blockquote>;
    case "code": return <pre><code>{text(record(block.content).text)}</code></pre>;
    case "table": return <div className="summary-table"><table>
      <thead><tr>{list(block.headers).map((cell, index) => <th key={index}><SummaryText value={cell} /></th>)}</tr></thead>
      <tbody>{list(block.rows).map((row, index) => <tr key={index}>{list(row).map((cell, column) => <td key={column}><SummaryText value={cell} /></td>)}</tr>)}</tbody>
    </table></div>;
    default: return <p>{content}</p>;
  }
}

export function SummaryContent({ document }: { document: Record<string, unknown> }) {
  if (!Array.isArray(document.sections)) return <p className="error" role="alert">{uiText("This summary could not be displayed.", "要約を表示できませんでした。")}</p>;
  const description = text(document.description);
  const actionItems = list(document.actionItems);
  return <div className="summary-document">
    {description && <p className="summary-description">{description}</p>}
    {document.sections.map((value, index) => {
      const section = record(value);
      const heading = text(section.heading);
      return <section key={index}>
        {heading && <h2>{heading}</h2>}
        {list(section.blocks).map((block, index) => <SummaryBlock key={index} value={block} />)}
      </section>;
    })}
    {actionItems.length > 0 && <section>
      <h2>{uiText("Action items", "アクションアイテム")}</h2>
      <ul>{actionItems.map((value, index) => {
        const item = record(value);
        const assignee = text(item.assignee);
        return <li key={index}>
          {text(item.title)}{assignee && <span className="timestamp">{assignee}</span>}
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
  return <time dateTime={startTime}>{timestamp}</time>;
}

export function MeetingTabs({ summary, screenshots, transcript, actions }: { summary: ReactNode; screenshots: ReactNode; transcript: ReactNode; actions?: ReactNode }) {
  const tabs = [
    { id: "summary", label: uiText("Summary", "要約"), content: summary },
    { id: "screenshots", label: uiText("Screenshots", "スクリーンショット"), content: screenshots },
    { id: "transcript", label: uiText("Transcript", "文字起こし"), content: transcript },
  ];
  const [selected, setSelected] = useState(0);
  const id = useId();
  return <>
    <div className="meeting-toolbar">
      <div className="meeting-tabs" role="tablist" aria-label={uiText("Meeting content", "ミーティングの内容")}>
        {tabs.map((tab, index) => <button key={tab.id} type="button" role="tab" id={`${id}-${tab.id}`} aria-controls={`${id}-panel-${tab.id}`}
          aria-selected={selected === index} tabIndex={selected === index ? 0 : -1} onClick={() => setSelected(index)}
          onKeyDown={(event) => {
            let next: number;
            if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
            else if (event.key === "ArrowLeft") next = (index + tabs.length - 1) % tabs.length;
            else if (event.key === "Home") next = 0;
            else if (event.key === "End") next = tabs.length - 1;
            else return;
            event.preventDefault();
            setSelected(next);
            document.getElementById(`${id}-${tabs[next]!.id}`)?.focus();
          }}>{tab.label}</button>)}
      </div>
      {actions}
    </div>
    {tabs.map((tab, index) => <div key={tab.id} role="tabpanel" id={`${id}-panel-${tab.id}`} aria-labelledby={`${id}-${tab.id}`}
      hidden={selected !== index} tabIndex={0} className="meeting-tab-content">{selected === index && tab.content}</div>)}
  </>;
}

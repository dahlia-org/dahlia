// A meeting, after MeetingDetailHeader, DetailTabBar and SummaryDocumentView: the header with recording and summary
// controls, processing banners, and the Summary and Transcript tabs.
import { useEffect, useRef, useState } from "react";
import { referenceMs, timestamp } from "../shared/format.js";
import type { Meeting, Progress, SummaryBlock, SummaryDocument } from "../shared/types.js";
import { api, useLive, type Recorder } from "./capture.js";
import { errorMessage, t } from "./i18n.js";
import { EllipsisIcon, RecordIcon, SparklesIcon, StopIcon } from "./icons.js";
import { Button, ConfirmDelete } from "./Modals.js";
import { MenuItem } from "./Sidebar.js";

type Tab = "summary" | "transcript";

export function MeetingView({ meetingId, recorder, onDeleted, onSummarize }: { meetingId: string; recorder: Recorder; onDeleted: () => void; onSummarize: () => void }) {
  const meeting = useLive(() => api.meetings.get(meetingId), [meetingId]);
  const progress = useLive(() => api.processing.progress(), []);
  const [tab, setTab] = useState<Tab>("summary");
  const [highlight, setHighlight] = useState<number>();
  const [confirmingDelete, setConfirmingDelete] = useState(false);

  if (!meeting) return <div className="flex-1" />;
  const recordingHere = recorder.active?.meetingId === meeting.id;
  const busy = recordingHere || meeting.recordings.some((item) => ["recording", "recorded", "transcribing"].includes(item.status)) || meeting.summary?.status === "generating";
  const current = progress?.find((item) => item.meetingId === meeting.id);
  const showReference = (reference: string) => {
    setHighlight(referenceMs(reference));
    setTab("transcript");
  };

  return (
    <div className="flex h-full min-w-0 flex-1 flex-col">
      <header className="drag flex h-8 shrink-0 items-center" />
      <div className="mx-auto flex w-full max-w-[1000px] items-center gap-3 px-6 pb-3">
        <MeetingTitle meeting={meeting} />
        <div className="ml-auto flex shrink-0 items-center gap-2">
          {recordingHere ? (
            <Button variant="danger" onClick={() => void recorder.stop()} title="⌘⇧R"><StopIcon />{t("stop")}</Button>
          ) : (
            <Button variant="danger" disabled={Boolean(recorder.active) || recorder.starting} onClick={() => void recorder.start(meeting.id)} title="⌘⇧R">
              <RecordIcon />{t("record")}
            </Button>
          )}
          <Button disabled={busy || meeting.segments.length === 0} onClick={onSummarize}>
            <SparklesIcon />{t("generateSummary")}
          </Button>
          <MoreMenu
            disabled={busy}
            canRetranscribe={meeting.recordings.some((item) => item.status === "transcribed" || item.status === "failed")}
            onRetranscribe={() => void api.processing.retranscribe(meeting.id)}
            onDelete={() => setConfirmingDelete(true)}
          />
        </div>
      </div>
      <div className="mx-auto w-full max-w-[1000px] px-6">
        <StatusBanners meeting={meeting} progress={current} recording={recordingHere} onSummarize={onSummarize} />
        <nav className="flex gap-1 border-b border-separator" role="tablist">
          {(["summary", "transcript"] as const).map((item) => (
            <button key={item} type="button" role="tab" aria-selected={tab === item} onClick={() => setTab(item)}
              className={`-mb-px border-b-2 px-3 py-[7px] ${tab === item ? "border-primary font-medium text-text" : "border-transparent text-secondary hover:text-text"}`}>
              {t(item)}
            </button>
          ))}
        </nav>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className="selectable mx-auto w-full max-w-[1000px] px-6 py-5">
          {tab === "summary"
            ? meeting.summary?.document ? <SummaryContent document={meeting.summary.document} onReference={showReference} /> : <Empty text={t("noSummary")} />
            : <TranscriptContent meeting={meeting} recording={recordingHere} highlight={highlight} />}
        </div>
      </div>
      {confirmingDelete && (
        <ConfirmDelete
          onCancel={() => setConfirmingDelete(false)}
          onConfirm={() => {
            setConfirmingDelete(false);
            void api.meetings.delete(meeting.id).then(onDeleted);
          }}
        />
      )}
    </div>
  );
}

function MeetingTitle({ meeting }: { meeting: Meeting }) {
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(meeting.name);
  useEffect(() => setName(meeting.name), [meeting.name]);
  const save = () => {
    setEditing(false);
    if (name.trim() && name.trim() !== meeting.name) void api.meetings.rename(meeting.id, name.trim());
    else setName(meeting.name);
  };
  return (
    <div className="flex min-w-0 flex-col">
      {editing ? (
        <input autoFocus value={name} maxLength={200} aria-label={t("rename")}
          className="selectable -mx-1 rounded-field border border-primary bg-content px-1 text-title font-semibold outline-none"
          onChange={(event) => setName(event.target.value)} onBlur={save}
          onKeyDown={(event) => {
            if (event.key === "Enter") save();
            if (event.key === "Escape") {
              setName(meeting.name);
              setEditing(false);
            }
          }} />
      ) : (
        <button type="button" title={t("rename")} onClick={() => setEditing(true)} className="-mx-1 truncate rounded-field px-1 text-left text-title font-semibold hover:bg-hover">
          {meeting.name}
        </button>
      )}
      {meeting.description && <p className="truncate text-small text-secondary">{meeting.description}</p>}
    </div>
  );
}

function MoreMenu({ disabled, canRetranscribe, onRetranscribe, onDelete }: { disabled: boolean; canRetranscribe: boolean; onRetranscribe: () => void; onDelete: () => void }) {
  const [open, setOpen] = useState(false);
  const container = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (event: MouseEvent) => !container.current?.contains(event.target as Node) && setOpen(false);
    window.addEventListener("mousedown", close);
    return () => window.removeEventListener("mousedown", close);
  }, [open]);
  return (
    <div ref={container} className="relative">
      <Button variant="plain" className="px-2" aria-label={t("more")} aria-expanded={open} onClick={() => setOpen(!open)}><EllipsisIcon /></Button>
      {open && (
        <div role="menu" className="absolute right-0 top-9 z-40 w-56 rounded-card bg-content p-1 shadow-xl ring-1 ring-separator">
          <MenuItem disabled={disabled || !canRetranscribe} onClick={() => { setOpen(false); onRetranscribe(); }}>{t("retranscribe")}</MenuItem>
          <MenuItem danger disabled={disabled} onClick={() => { setOpen(false); onDelete(); }}>{t("deleteMeeting")}</MenuItem>
        </div>
      )}
    </div>
  );
}

function StatusBanners({ meeting, progress, recording, onSummarize }: { meeting: Meeting; progress: Progress | undefined; recording: boolean; onSummarize: () => void }) {
  const banners: { key: string; tone: "info" | "error"; text: string; action?: { label: string; run: () => void } }[] = [];
  const failed = meeting.recordings.find((item) => item.status === "failed");
  const waiting = meeting.recordings.some((item) => item.status === "recorded" || item.status === "transcribing");
  if (progress?.step === "transcribing") {
    const percent = progress.fraction === undefined ? "" : ` ${Math.round(progress.fraction * 100)}%`;
    banners.push({ key: "transcribing", tone: "info", text: `${t(progress.detail === "downloadingModel" ? "downloadingModel" : "transcribing")}…${percent}` });
  } else if (waiting) {
    banners.push({ key: "waiting", tone: "info", text: `${t("waitingTranscription")}…` });
  }
  if (failed && !waiting && !recording) {
    banners.push({ key: "failed", tone: "error", text: `${t("transcriptionFailed")}: ${errorMessage(failed.error)}`, action: { label: t("retry"), run: () => void api.processing.retranscribe(meeting.id) } });
  }
  if (meeting.summary?.status === "generating" && !waiting) banners.push({ key: "summarizing", tone: "info", text: t("summarizing") });
  if (meeting.summary?.status === "failed") {
    banners.push({ key: "summaryFailed", tone: "error", text: `${t("summaryFailed")}: ${errorMessage(meeting.summary.error)}`, action: { label: t(meeting.summary.error === "auth_signedOut" ? "signIn" : "retry"), run: onSummarize } });
  }
  if (banners.length === 0) return null;
  return (
    <div className="mb-3 flex flex-col gap-2">
      {banners.map((banner) => (
        <div key={banner.key} role={banner.tone === "error" ? "alert" : "status"}
          className={`flex items-center gap-3 rounded-card px-3 py-2 ${banner.tone === "error" ? "bg-danger/10 text-danger" : "bg-highlight text-text"}`}>
          {banner.tone === "info" && <span className="size-3 shrink-0 animate-spin rounded-full border-2 border-primary border-t-transparent" aria-hidden />}
          <span className="min-w-0 flex-1">{banner.text}</span>
          {banner.action && !waiting && !recording && <Button onClick={banner.action.run}>{banner.action.label}</Button>}
        </div>
      ))}
    </div>
  );
}

function Empty({ text }: { text: string }) {
  return <p className="py-10 text-center text-secondary">{text}</p>;
}

function Reference({ value, onReference }: { value: string | null; onReference: (reference: string) => void }) {
  if (!value) return null;
  return (
    <button type="button" onClick={() => onReference(value)} className="ml-1.5 rounded-md bg-highlight px-1.5 align-[1px] font-mono text-[11px] text-primary hover:brightness-95">
      {value}
    </button>
  );
}

function SummaryContent({ document, onReference }: { document: SummaryDocument; onReference: (reference: string) => void }) {
  return (
    <article className="flex flex-col gap-[14px] leading-[1.55]">
      {document.sections.map((section, index) => (
        <section key={index} className="flex flex-col gap-[14px]">
          {section.heading && <h3 className="mt-2 text-title2 font-semibold">{section.heading}</h3>}
          {section.blocks.map((block, blockIndex) => <Block key={blockIndex} block={block} onReference={onReference} />)}
        </section>
      ))}
      {document.action_items.length > 0 && (
        <section className="flex flex-col gap-[14px]">
          <h3 className="mt-2 text-title2 font-semibold">{t("actionItems")}</h3>
          <ul className="flex flex-col gap-1.5">
            {document.action_items.map((item, index) => (
              <li key={index} className="flex gap-2">
                <input type="checkbox" disabled className="mt-1" aria-hidden />
                <span>
                  {item.text}
                  {item.assignee && <span className="ml-1.5 text-secondary">— {item.assignee}</span>}
                  <Reference value={item.transcript_ref} onReference={onReference} />
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </article>
  );
}

function Block({ block, onReference }: { block: SummaryBlock; onReference: (reference: string) => void }) {
  switch (block.type) {
    case "heading":
      return <h4 className="text-title3 font-semibold">{block.text}<Reference value={block.transcript_ref} onReference={onReference} /></h4>;
    case "paragraph":
      return <p>{block.text}<Reference value={block.transcript_ref} onReference={onReference} /></p>;
    case "bulleted_list":
    case "numbered_list": {
      const List = block.type === "numbered_list" ? "ol" : "ul";
      return (
        <List className={`flex flex-col gap-1.5 pl-5 ${block.type === "numbered_list" ? "list-decimal" : "list-disc"}`}>
          {block.items.map((item, index) => <li key={index}>{item.text}<Reference value={item.transcript_ref} onReference={onReference} /></li>)}
        </List>
      );
    }
    case "checklist":
      return (
        <ul className="flex flex-col gap-1.5">
          {block.items.map((item, index) => (
            <li key={index} className="flex gap-2">
              <input type="checkbox" checked={item.checked} disabled className="mt-1" readOnly />
              <span>{item.text}<Reference value={item.transcript_ref} onReference={onReference} /></span>
            </li>
          ))}
        </ul>
      );
  }
}

function TranscriptContent({ meeting, recording, highlight }: { meeting: Meeting; recording: boolean; highlight: number | undefined }) {
  const target = useRef<HTMLLIElement>(null);
  const highlighted = highlight === undefined ? undefined
    : meeting.segments.findLast((segment) => segment.offsetMs + segment.startMs <= highlight + 999)?.id ?? meeting.segments[0]?.id;
  useEffect(() => target.current?.scrollIntoView({ block: "center" }), [highlighted]);
  if (meeting.segments.length === 0) return <Empty text={recording ? t("recordingInProgress") : t("noTranscript")} />;
  return (
    <ol className="flex flex-col gap-3">
      {meeting.segments.map((segment) => (
        <li key={segment.id} ref={segment.id === highlighted ? target : undefined}
          className={`grid grid-cols-[72px_1fr] gap-3 rounded-field px-2 py-1 ${segment.id === highlighted ? "bg-highlight" : ""}`}>
          <span className="flex flex-col text-small text-secondary">
            <span className="font-mono tabular-nums">{timestamp(segment.offsetMs + segment.startMs)}</span>
            <span>{t(segment.source)}</span>
          </span>
          <span className="leading-[1.55]">{segment.text}</span>
        </li>
      ))}
    </ol>
  );
}

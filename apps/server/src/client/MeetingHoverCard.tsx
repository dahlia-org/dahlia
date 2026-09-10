import { useEffect, useLayoutEffect, useId, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { AppearanceIcon, type Appearance } from "./AppearancePicker";
import { uiText, type SyncedMeetingInfo } from "./api";

export function MeetingHoverDetails({ meeting, projectName, appearance }: {
  meeting: SyncedMeetingInfo; projectName?: string; appearance?: Appearance;
}) {
  const date = meeting.recordingStartedAt ?? meeting.createdAt;
  const minutes = meeting.duration == null ? null : Math.floor(Math.max(0, meeting.duration) / 60);
  return <>
    <div className="meeting-preview-heading"><strong>{meeting.name || uiText("Untitled meeting", "無題のミーティング")}</strong>
      <span>{meeting.isRecording ? uiText("Recording", "録音中") : minutes == null ? "—" : uiText(`${minutes} min`, `${minutes}分`)}</span></div>
    {projectName && <div className="meeting-preview-project"><AppearanceIcon appearance={appearance ?? { icon: "folder", color: "neutral" }} /><span>{projectName}</span></div>}
    <time dateTime={date}>{new Date(date).toLocaleString(undefined, { year: "numeric", month: "long", day: "numeric", hour: "2-digit", minute: "2-digit" })}</time>
    <p>{meeting.description?.trim() || "—"}</p>
  </>;
}

export function MeetingHoverCard({ meeting, projectName, appearance, active, children }: {
  meeting: SyncedMeetingInfo; projectName?: string; appearance?: Appearance; active: boolean; children: ReactNode;
}) {
  return <li className={`tree-row meeting-row${active ? " active" : ""}`}>
    <HoverPreview details={<MeetingHoverDetails meeting={meeting} projectName={projectName} appearance={appearance} />}>
      {(describedBy) => <a href={`/meetings/${meeting.meetingId}`} aria-current={active ? "page" : undefined} aria-describedby={describedBy}>{children}</a>}
    </HoverPreview>
  </li>;
}

export function HoverPreview({ details, children }: { details: ReactNode; children: (describedBy?: string) => ReactNode }) {
  const id = useId();
  const row = useRef<HTMLDivElement>(null);
  const card = useRef<HTMLDivElement>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [position, setPosition] = useState<{ left: number; top: number } | null>(null);
  const cancel = () => clearTimeout(timer.current);
  const close = () => { cancel(); setPosition(null); };
  const show = () => {
    cancel();
    const rect = row.current?.getBoundingClientRect();
    if (rect) setPosition({ left: Math.max(8, Math.min(rect.right + 6, window.innerWidth - 376)), top: Math.max(8, Math.min(rect.top, window.innerHeight - 8)) });
  };
  const leave = () => { cancel(); timer.current = setTimeout(close, 150); };
  useEffect(() => () => clearTimeout(timer.current), []);
  useLayoutEffect(() => {
    if (position && card.current) card.current.style.top = `${Math.max(8, Math.min(position.top, window.innerHeight - card.current.offsetHeight - 8))}px`;
  }, [position, details]);
  useEffect(() => {
    if (!position) return;
    const dismiss = () => { clearTimeout(timer.current); setPosition(null); };
    const keydown = (event: KeyboardEvent) => { if (event.key === "Escape") dismiss(); };
    window.addEventListener("resize", dismiss);
    document.addEventListener("scroll", dismiss, true);
    document.addEventListener("keydown", keydown);
    return () => {
      window.removeEventListener("resize", dismiss);
      document.removeEventListener("scroll", dismiss, true);
      document.removeEventListener("keydown", keydown);
    };
  }, [position]);
  return <div ref={row} className="hover-preview-trigger"
    onPointerEnter={(event) => { if (event.pointerType !== "touch") { cancel(); timer.current = setTimeout(show, 350); } }}
    onPointerLeave={leave} onFocus={show} onBlur={close} onClick={close}>
    {children(position ? id : undefined)}
    {position && createPortal(<div ref={card} id={id} role="tooltip" className="meeting-preview" style={position}
      onPointerEnter={cancel} onPointerLeave={leave}>
      {details}
    </div>, document.body)}
  </div>;
}

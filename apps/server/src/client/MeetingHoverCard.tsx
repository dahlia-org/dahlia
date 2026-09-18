import { createContext, useCallback, useContext, useEffect, useId, useRef, useState, type ReactNode } from "react";
import { AppearanceIcon, type Appearance } from "./AppearancePicker";
import { HoverCard, HoverCardContent, HoverCardTrigger } from "./components/ui/hover-card";
import { uiText, type SyncedMeetingInfo } from "./api";

const HoverPreviewDelayContext = createContext<{ warm: boolean; update: (open: boolean) => void } | null>(null);

export function HoverPreviewProvider({ children }: { children: ReactNode }) {
  const [warm, setWarm] = useState(false);
  const openCount = useRef(0);
  const cooldown = useRef<ReturnType<typeof setTimeout>>(undefined);
  const update = useCallback((open: boolean) => {
    openCount.current += open ? 1 : -1;
    clearTimeout(cooldown.current);
    if (openCount.current > 0) setWarm(true);
    else cooldown.current = setTimeout(() => setWarm(false), 700);
  }, []);
  useEffect(() => () => clearTimeout(cooldown.current), []);
  return <HoverPreviewDelayContext.Provider value={{ warm, update }}>{children}</HoverPreviewDelayContext.Provider>;
}

export function MeetingHoverDetails({ meeting, projectName, appearance }: {
  meeting: SyncedMeetingInfo; projectName?: string; appearance?: Appearance;
}) {
  const date = meeting.recordingStartedAt ?? meeting.createdAt;
  const minutes = meeting.duration == null ? null : Math.floor(Math.max(0, meeting.duration) / 60);
  return <>
    <div className="flex items-baseline gap-3"><strong className="min-w-0 flex-1 line-clamp-2">{meeting.name || uiText("Untitled meeting", "無題のミーティング")}</strong>
      <span className="shrink-0 text-xs text-muted-foreground">{meeting.isRecording ? uiText("Recording", "録音中") : minutes == null ? "—" : uiText(`${minutes} min`, `${minutes}分`)}</span></div>
    {projectName && <div className="mt-2 flex items-center gap-2 text-sm"><AppearanceIcon appearance={appearance ?? { icon: "folder", color: "neutral" }} /><span className="truncate">{projectName}</span></div>}
    <time className="mt-2 block text-xs text-muted-foreground" dateTime={date}>{new Date(date).toLocaleString(undefined, { year: "numeric", month: "long", day: "numeric", hour: "2-digit", minute: "2-digit" })}</time>
    <p className="mt-2 line-clamp-3 text-sm text-muted-foreground">{meeting.description?.trim() || "—"}</p>
  </>;
}

export function MeetingHoverCard({ meeting, projectName, appearance, active, children }: {
  meeting: SyncedMeetingInfo; projectName?: string; appearance?: Appearance; active: boolean; children: ReactNode;
}) {
  return <li className={active ? "rounded-md bg-accent text-accent-foreground" : "rounded-md hover:bg-accent/70"}>
    <HoverPreview details={<MeetingHoverDetails meeting={meeting} projectName={projectName} appearance={appearance} />}>
      {(describedBy) => <a className="block min-w-0 px-3 py-2" href={`/meetings/${meeting.meetingId}`} aria-current={active ? "page" : undefined} aria-describedby={describedBy}>{children}</a>}
    </HoverPreview>
  </li>;
}

export function HoverPreview({ details, children }: { details: ReactNode; children: (describedBy?: string) => ReactNode }) {
  const id = useId();
  const delay = useContext(HoverPreviewDelayContext);
  const updateDelay = delay?.update;
  const open = useRef(false);
  useEffect(() => () => { if (open.current) updateDelay?.(false); }, [updateDelay]);
  return <HoverCard openDelay={delay?.warm ? 0 : 700} closeDelay={150} onOpenChange={(next) => {
    if (open.current === next) return;
    open.current = next;
    updateDelay?.(next);
  }}>
    <HoverCardTrigger asChild>{children(id)}</HoverCardTrigger>
    <HoverCardContent id={id} side="right" align="start" className="w-80">{details}</HoverCardContent>
  </HoverCard>;
}

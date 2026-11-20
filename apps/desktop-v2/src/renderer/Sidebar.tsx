// The sidebar, after MeetingListSidebarView and MainSidebarFooterView: meetings newest first, the recording status and
// the account button at the bottom (58 px).
import { useEffect, useRef, useState } from "react";
import { timestamp } from "../shared/format.js";
import type { AuthState, MeetingSummary } from "../shared/types.js";
import type { Recorder } from "./capture.js";
import { dateTime, errorMessage, t } from "./i18n.js";
import { GearIcon, PersonIcon, PlusIcon } from "./icons.js";

export function Sidebar({ meetings, selected, onSelect, onCreate, recorder, auth, onSettings, onSignIn, onSignOut }: {
  meetings: MeetingSummary[] | undefined;
  selected: string | undefined;
  onSelect: (id: string) => void;
  onCreate: () => void;
  recorder: Recorder;
  auth: Extract<AuthState, { status: "signedIn" }> | undefined;
  onSettings: () => void;
  onSignIn: () => void;
  onSignOut: () => void;
}) {
  return (
    <aside className="flex h-full flex-col text-sidebar-text" style={{ width: "var(--sidebar-width)" }}>
      <div className="drag h-8 shrink-0" />
      <div className="px-2.5 pb-2">
        <button type="button" onClick={onCreate} className="flex h-8 w-full items-center gap-2 rounded-field px-2.5 text-left hover:bg-hover">
          <PlusIcon className="text-primary" />
          {t("newMeeting")}
        </button>
      </div>
      <div className="px-5 pb-1 text-small font-medium text-secondary">{t("meetings")}</div>
      <nav className="min-h-0 flex-1 overflow-y-auto px-2.5 pb-2">
        {meetings?.length === 0 && <p className="px-2.5 py-2 text-small text-secondary">{t("noMeetings")}</p>}
        {meetings?.map((meeting) => (
          <button
            key={meeting.id}
            type="button"
            onClick={() => onSelect(meeting.id)}
            className={`flex w-full flex-col rounded-field px-2.5 py-1.5 text-left ${meeting.id === selected ? "bg-highlight" : "hover:bg-hover"}`}
          >
            <span className="flex w-full items-center gap-1.5">
              <span className="truncate">{meeting.name}</span>
              {recorder.active?.meetingId === meeting.id
                ? <span className="ml-auto size-2 shrink-0 rounded-full bg-danger" aria-label={t("recording")} />
                : meeting.busy && <span className="ml-auto size-2 shrink-0 animate-pulse rounded-full bg-primary" aria-hidden />}
            </span>
            <span className="text-small text-secondary">{dateTime.format(meeting.createdAt)}</span>
          </button>
        ))}
      </nav>
      {recorder.active && <RecordingStatusBar recorder={recorder} />}
      {!recorder.active && recorder.error && <p className="mx-3 mb-2 rounded-field bg-surface p-2 text-small text-danger">{errorMessage(recorder.error)}</p>}
      <div className="flex h-[58px] shrink-0 items-center border-t border-separator px-2.5">
        <AccountButton auth={auth} onSettings={onSettings} onSignIn={onSignIn} onSignOut={onSignOut} />
      </div>
    </aside>
  );
}

function RecordingStatusBar({ recorder }: { recorder: Recorder }) {
  return (
    <div className="mx-2.5 mb-2 flex flex-col gap-1.5 rounded-card bg-surface p-2.5">
      <div className="flex items-center gap-2">
        <span className="size-2 animate-pulse rounded-full bg-danger" aria-hidden />
        <span className="font-medium">{t("recording")}</span>
        <span className="ml-auto font-mono text-small tabular-nums">{timestamp(recorder.elapsedMs)}</span>
      </div>
      <LevelMeter label={t("mic")} level={recorder.levels.mic} />
      <LevelMeter label={t("system")} level={recorder.levels.system} />
      {recorder.systemWarning && <p className="text-small text-secondary">{t(recorder.systemWarning)}</p>}
    </div>
  );
}

/** Segments like RecordingInputLevelMeter: ten steps on a decibel scale from -60 dB. */
function LevelMeter({ label, level }: { label: string; level: number }) {
  const steps = 10;
  const lit = Math.round(Math.max(0, Math.min(1, (20 * Math.log10(Math.max(level, 1e-6)) + 60) / 60)) * steps);
  return (
    <div className="flex items-center gap-2 text-small text-secondary">
      <span className="w-20 truncate">{label}</span>
      <span className="flex flex-1 gap-0.5" role="meter" aria-label={label} aria-valuemin={0} aria-valuemax={steps} aria-valuenow={lit}>
        {Array.from({ length: steps }, (_, index) => (
          <span key={index} className={`h-1.5 flex-1 rounded-sm ${index < lit ? (index >= 8 ? "bg-danger" : "bg-primary") : "bg-separator"}`} />
        ))}
      </span>
    </div>
  );
}

function AccountButton({ auth, onSettings, onSignIn, onSignOut }: {
  auth: Extract<AuthState, { status: "signedIn" }> | undefined;
  onSettings: () => void;
  onSignIn: () => void;
  onSignOut: () => void;
}) {
  const [open, setOpen] = useState(false);
  const container = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (event: MouseEvent) => !container.current?.contains(event.target as Node) && setOpen(false);
    const escape = (event: KeyboardEvent) => event.key === "Escape" && setOpen(false);
    window.addEventListener("mousedown", close);
    window.addEventListener("keydown", escape);
    return () => {
      window.removeEventListener("mousedown", close);
      window.removeEventListener("keydown", escape);
    };
  }, [open]);
  const host = auth ? new URL(auth.workspace).host.split(".")[0] : t("thisMac");
  return (
    <div ref={container} className="relative w-full">
      <button type="button" onClick={() => setOpen(!open)} className="flex h-10 w-full items-center gap-2.5 rounded-field px-2 text-left hover:bg-hover" aria-expanded={open}>
        <span className="flex size-7 shrink-0 items-center justify-center rounded-full bg-highlight text-primary"><PersonIcon /></span>
        <span className="flex min-w-0 flex-col leading-tight">
          <span className="truncate">{host}</span>
          <span className="truncate text-small text-secondary">{auth?.email ?? t("notSignedIn")}</span>
        </span>
      </button>
      {open && (
        <div role="menu" className="absolute bottom-12 left-0 z-40 w-56 rounded-card bg-content p-1 shadow-xl ring-1 ring-separator">
          <MenuItem onClick={() => { setOpen(false); onSettings(); }}><GearIcon />{t("settings")}</MenuItem>
          <MenuItem onClick={() => { setOpen(false); if (auth) onSignOut(); else onSignIn(); }}>{t(auth ? "signOut" : "signIn")}</MenuItem>
        </div>
      )}
    </div>
  );
}

export function MenuItem({ onClick, children, danger = false, disabled = false }: { onClick: () => void; children: React.ReactNode; danger?: boolean; disabled?: boolean }) {
  return (
    <button type="button" role="menuitem" disabled={disabled} onClick={onClick}
      className={`flex h-8 w-full items-center gap-2 rounded-field px-2.5 text-left hover:bg-hover disabled:opacity-40 ${danger ? "text-danger" : "text-text"}`}>
      {children}
    </button>
  );
}

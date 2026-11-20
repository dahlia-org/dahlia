// The window: the sidebar over the window's vibrancy (275 px, 240–520 resizable) and the meeting on the content
// background, as in Dahlia for macOS's ContentView. Signing in is required before anything else.
import { useEffect, useState } from "react";
import { api, useLive, useRecorder } from "./capture.js";
import { t } from "./i18n.js";
import { MeetingView } from "./MeetingView.js";
import { SettingsModal, SignIn } from "./Modals.js";
import { Sidebar } from "./Sidebar.js";

const sidebar = { min: 240, max: 520, initial: 275 };

export function App() {
  const auth = useLive(() => api.auth.state(), []);
  const meetings = useLive(() => api.meetings.list(), []);
  const recorder = useRecorder();
  const [selected, setSelected] = useState<string>();
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [width, setWidth] = useState(() => Number(localStorage.getItem("sidebarWidth")) || sidebar.initial);
  const signedIn = auth?.status === "signedIn" ? auth : undefined;

  useEffect(() => {
    if (meetings && !meetings.some((meeting) => meeting.id === selected)) setSelected(meetings[0]?.id);
  }, [meetings, selected]);

  // ⌘⇧R starts or stops recording the open meeting, as in Dahlia for macOS.
  useEffect(() => {
    const listener = (event: KeyboardEvent) => {
      if (!(event.metaKey && event.shiftKey && event.key.toLowerCase() === "r") || !signedIn) return;
      event.preventDefault();
      if (recorder.active) void recorder.stop();
      else if (selected) void recorder.start(selected);
    };
    window.addEventListener("keydown", listener);
    return () => window.removeEventListener("keydown", listener);
  }, [recorder, selected, signedIn]);

  const create = async () => setSelected(await api.meetings.create());

  const resize = (event: React.PointerEvent) => {
    const startX = event.clientX;
    const startWidth = width;
    const move = (next: PointerEvent) => setWidth(Math.min(sidebar.max, Math.max(sidebar.min, startWidth + next.clientX - startX)));
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      setWidth((value) => {
        localStorage.setItem("sidebarWidth", String(value));
        return value;
      });
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };

  return (
    <div className="flex h-full" style={{ "--sidebar-width": `${width}px` } as React.CSSProperties}>
      <Sidebar
        meetings={signedIn ? meetings : []}
        selected={selected}
        onSelect={setSelected}
        onCreate={() => void create()}
        recorder={recorder}
        auth={signedIn}
        onSettings={() => setSettingsOpen(true)}
        onSignOut={() => void api.auth.signOut()}
      />
      <div className="no-drag relative w-px shrink-0 bg-separator">
        <div role="separator" aria-orientation="vertical" onPointerDown={resize} className="absolute inset-y-0 -left-1 z-10 w-2 cursor-col-resize" />
      </div>
      <main className="flex min-w-0 flex-1 bg-content">
        {signedIn && selected
          ? <MeetingView key={selected} meetingId={selected} recorder={recorder} onDeleted={() => setSelected(undefined)} />
          : (
            <div className="flex flex-1 flex-col">
              <div className="drag h-8" />
              <p className="m-auto text-secondary">{signedIn ? t("noMeetingSelected") : ""}</p>
            </div>
          )}
      </main>
      {auth && !signedIn && <SignIn auth={auth} />}
      {settingsOpen && signedIn && <SettingsModal auth={signedIn} onClose={() => setSettingsOpen(false)} />}
    </div>
  );
}

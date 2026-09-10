// Run pnpm dev:client and open /tests/browser/meeting-hover.html. No backend is contacted.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { MeetingHoverCard } from "../../src/client/MeetingHoverCard";
import type { SyncedMeetingInfo } from "../../src/client/api";
import "../../src/client/styles.css";

const meeting = { meetingId: "preview", name: "リリース計画：次のバージョンの機能と検証方針を確認", duration: 3360,
  createdAt: "2026-09-10T06:00:00Z", description: "次のリリースに含める変更と検証項目を確認し、担当とスケジュールを決定。残っている課題と次回までの作業を整理。" } as SyncedMeetingInfo;
flushSync(() => createRoot(document.getElementById("root")!).render(<nav style={{ width: 300, height: 400, overflow: "auto" }}>
  <ul><MeetingHoverCard meeting={meeting} projectName="Release planning" active={false}><span>{meeting.name}</span></MeetingHoverCard></ul>
</nav>));
const link = document.querySelector("a")!;
const assert = (condition: boolean, message: string) => { if (!condition) throw new Error(message); };
try {
  flushSync(() => link.focus());
  const card = document.querySelector<HTMLElement>('[role="tooltip"]')!;
  assert(!!card, "Focus opens preview");
  assert(link.getAttribute("aria-describedby") === card.id, "Preview describes link");
  assert(card.getBoundingClientRect().left >= link.getBoundingClientRect().right, "Preview is to the right");
  assert(card.getBoundingClientRect().bottom <= innerHeight, "Preview stays in viewport");
  flushSync(() => document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" })));
  assert(!document.querySelector('[role="tooltip"]'), "Escape dismisses preview");
  flushSync(() => link.blur());
  flushSync(() => link.focus());
  flushSync(() => document.dispatchEvent(new Event("scroll")));
  assert(!document.querySelector('[role="tooltip"]'), "Scrolling dismisses preview");
  link.blur();
  link.dispatchEvent(new PointerEvent("pointerover", { bubbles: true, pointerType: "mouse" }));
  await new Promise((resolve) => setTimeout(resolve, 450));
  assert(!!document.querySelector('[role="tooltip"]'), "Hover opens preview");
  document.getElementById("result")!.textContent = "PASS: hover, focus, description, position, Escape, scroll";
} catch (error) {
  document.getElementById("result")!.textContent = `FAIL: ${String(error)}`;
  throw error;
}

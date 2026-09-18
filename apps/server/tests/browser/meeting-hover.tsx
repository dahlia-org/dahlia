// Run pnpm dev:client and open /tests/browser/meeting-hover.html. No backend is contacted.
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { HoverPreviewProvider, MeetingHoverCard } from "../../src/client/MeetingHoverCard";
import type { SyncedMeetingInfo } from "../../src/client/api";
import "../../src/client/styles.css";

const meeting = { meetingId: "preview", name: "リリース計画：次のバージョンの機能と検証方針を確認", duration: 3360,
  createdAt: "2026-09-10T06:00:00Z", description: "次のリリースに含める変更と検証項目を確認し、担当とスケジュールを決定。残っている課題と次回までの作業を整理。" } as SyncedMeetingInfo;
flushSync(() => createRoot(document.getElementById("root")!).render(<nav style={{ width: 300, height: 400, overflow: "auto" }}>
  <HoverPreviewProvider><ul><MeetingHoverCard meeting={meeting} projectName="Release planning" active={false}><span>{meeting.name}</span></MeetingHoverCard>
    <MeetingHoverCard meeting={{ ...meeting, meetingId: "adjacent", name: "Adjacent meeting" }} projectName="Release planning" active={false}><span>Adjacent meeting</span></MeetingHoverCard>
  </ul></HoverPreviewProvider>
</nav>));
const links = document.querySelectorAll<HTMLAnchorElement>("a");
const link = links[0]!;
const adjacent = links[1]!;
const assert = (condition: boolean, message: string) => { if (!condition) throw new Error(message); };
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 2000;
  while (!predicate()) {
    if (performance.now() > deadline) throw new Error("Timed out waiting for hover preview");
    await new Promise(requestAnimationFrame);
  }
}
try {
  flushSync(() => link.focus());
  await until(() => document.querySelector('[data-slot="hover-card-content"]'));
  const card = document.querySelector<HTMLElement>('[data-slot="hover-card-content"]')!;
  assert(!!card, "Focus opens preview");
  assert(link.getAttribute("aria-describedby") === card.id, "Preview describes link");
  assert(card.getBoundingClientRect().left >= link.getBoundingClientRect().right, "Preview is to the right");
  assert(card.getBoundingClientRect().bottom <= innerHeight, "Preview stays in viewport");
  flushSync(() => link.blur());
  await until(() => !document.querySelector('[data-slot="hover-card-content"]'));
  await new Promise((resolve) => setTimeout(resolve, 750));
  link.dispatchEvent(new PointerEvent("pointerover", { bubbles: true, pointerType: "mouse" }));
  await new Promise((resolve) => setTimeout(resolve, 350));
  assert(!document.querySelector('[data-slot="hover-card-content"]'), "Hover preview opened before 700ms");
  await new Promise((resolve) => setTimeout(resolve, 500));
  assert(!!document.querySelector('[data-slot="hover-card-content"]'), "Hover opens preview after 700ms");
  link.dispatchEvent(new PointerEvent("pointerout", { bubbles: true, pointerType: "mouse", relatedTarget: adjacent }));
  adjacent.dispatchEvent(new PointerEvent("pointerover", { bubbles: true, pointerType: "mouse", relatedTarget: link }));
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert([...document.querySelectorAll('[data-slot="hover-card-content"]')].some((node) => node.textContent?.includes("Adjacent meeting")), "Adjacent preview repeated the 700ms delay");
  document.getElementById("result")!.textContent = "PASS: shared 700ms hover delay, adjacent skip, focus, description, position, blur";
} catch (error) {
  document.getElementById("result")!.textContent = `FAIL: ${String(error)}`;
  throw error;
}

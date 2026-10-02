// Run pnpm dev:client and open /tests/browser/breadcrumbs.html at desktop and mobile widths.
import { createRoot } from "react-dom/client";
import { BreadcrumbHeader } from "../../src/client/App";
import "../../src/client/styles.css";

const workspace = "ワークスペース".repeat(20);
const project = "プロジェクト".repeat(20);
const meeting = "PCA×CTC 全体プロジェクト会議：全体アーキテクチャ設計のリカバリープラン".repeat(4);
const meetings = [{ kind: "meeting" as const, href: "/meeting", label: meeting }];
const projects = [{ href: "/project", label: project, children: meetings }];
createRoot(document.getElementById("root")!).render(<article className="main-column" style={{ paddingTop: 48 }}>
  <BreadcrumbHeader segments={[
    { label: workspace, href: "/workspace", menuLabel: "ワークスペース", options: [{ href: "/workspace", label: workspace, children: projects }] },
    { label: project, href: "/project", menuLabel: "プロジェクト", options: projects },
    { kind: "meeting", label: meeting, current: true, menuLabel: "ミーティング", options: meetings },
  ]} actions={<button>Options</button>} />
</article>);
const assert = (condition: boolean, message: string) => { if (!condition) throw new Error(message); };
async function until(predicate: () => unknown, message = "Timed out waiting for breadcrumbs") {
  const deadline = performance.now() + 3000;
  while (!predicate()) {
    if (performance.now() > deadline) throw new Error(message);
    await new Promise(requestAnimationFrame);
  }
}
async function run() {
  await until(() => document.querySelectorAll(".breadcrumb-trigger").length === 3);
  const triggers = [...document.querySelectorAll<HTMLElement>(".breadcrumb-trigger")];
  for (const trigger of triggers) {
    const text = trigger.querySelector("span")!;
    assert(text.scrollWidth > text.clientWidth, "Long header name is not truncated");
    assert(getComputedStyle(text).textOverflow === "ellipsis", "Missing header ellipsis");
    assert(trigger.title === text.textContent, "Full name missing from title");
    trigger.focus();
    await until(() => document.querySelector('[data-slot="hover-card-content"]'));
    const card = document.querySelector<HTMLElement>('[data-slot="hover-card-content"]')!;
    const expected = Math.min(trigger.dataset.kind === "meeting" ? 520 : 260, innerWidth - 24);
    await until(() => Math.abs(card.getBoundingClientRect().width - expected) < 1);
    const textInMenu = card.querySelector("a span")!;
    assert(textInMenu.scrollWidth > textInMenu.clientWidth, "Long menu name is not truncated");
    assert(getComputedStyle(textInMenu).textOverflow === "ellipsis", "Missing menu ellipsis");
    assert(card.querySelector("a")!.title === textInMenu.textContent, "Full menu name missing");
    if (innerWidth >= 768) {
      let menu = card.querySelector<HTMLElement>("nav")!;
      let submenuTrigger = menu.querySelector<HTMLAnchorElement>(":scope > a[data-breadcrumb-submenu-trigger]");
      while (submenuTrigger) {
        submenuTrigger.parentElement!.dispatchEvent(new PointerEvent("pointerout", { bubbles: true, pointerType: "mouse", relatedTarget: submenuTrigger }));
        submenuTrigger.dispatchEvent(new PointerEvent("pointerover", { bubbles: true, pointerType: "mouse", relatedTarget: submenuTrigger.parentElement }));
        await until(() => menu.querySelector(".breadcrumb-submenu"));
        const nested = menu.querySelector<HTMLElement>(".breadcrumb-submenu")!;
        const expectedWidth = Math.min(nested.dataset.wide ? 520 : 256, innerWidth - 24);
        await until(() => {
          const bounds = nested.getBoundingClientRect();
          return bounds.left >= 0 && bounds.right <= innerWidth;
        });
        const bounds = nested.getBoundingClientRect();
        assert(bounds.width <= expectedWidth, "Nested menu exceeds its requested width");
        assert(Math.abs(bounds.width - Math.min(expectedWidth, parseFloat(getComputedStyle(nested).maxWidth))) < 1, "Nested menu ignores available width");
        assert(bounds.left >= 0 && bounds.right <= innerWidth, "Nested menu overflows viewport");
        const nestedText = nested.querySelector("a span")!;
        await until(() => nestedText.scrollWidth > nestedText.clientWidth);
        assert(nestedText.scrollWidth > nestedText.clientWidth, "Nested name is not truncated");
        menu = nested.querySelector<HTMLElement>("nav")!;
        submenuTrigger = menu.querySelector<HTMLAnchorElement>(":scope > a[data-breadcrumb-submenu-trigger]");
      }
      (document.activeElement as HTMLElement).blur();
    }
    card.dispatchEvent(new PointerEvent("pointerout", { bubbles: true, pointerType: "mouse", relatedTarget: document.body }));
    trigger.blur();
    await until(() => !document.querySelector('[data-slot="hover-card-content"]'), "Menu did not close after pointer exit and blur");
  }
  const actions = document.querySelector(".detail-header button:last-child")!.getBoundingClientRect();
  assert(actions.right <= innerWidth && actions.left >= 0, "Actions overflow viewport");
  document.getElementById("result")!.textContent = "PASS: header and menu truncation, full names, meeting menu widths, visible actions";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = "FAIL: " + String(error); });

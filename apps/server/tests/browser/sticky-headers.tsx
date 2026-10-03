// Open /tests/browser/sticky-headers.html at desktop and mobile widths. No backend is contacted.
import { createRoot } from "react-dom/client";
import { AppShell, DetailHeaderBar, PageHeader } from "@dahlia-ai/ui/layout/AppShell";
import "@dahlia-ai/ui/styles.css";

globalThis.fetch = () => Promise.resolve(Response.json({ items: [] }));
const root = createRoot(document.getElementById("root")!);
const frame = () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
const assert: (value: unknown, message: string) => asserts value = (value, message) => { if (!value) throw new Error(message); };

async function run() {
  for (const variant of ["page", "detail", "chat"] as const) {
    root.render(<AppShell brand="Dahlia" extensionPaths={[]} navigate={() => {}} path={variant === "chat" ? "/chat" : "/workspaces"}
      session={{ user: { id: "test" }, capabilities: { admin: false, sessions: false, sharing: false, sync: false, ai: true } }}>
      <article className={variant === "chat" ? "ai-chat" : "main-column"}>
        {variant === "page" ? <PageHeader title="Page title" actions={<button>Options</button>} />
          : variant === "detail" ? <DetailHeaderBar className="-mt-6 mb-12" actions={<button>Options</button>}>Detail title</DetailHeaderBar>
          : <header className="ai-header"><DetailHeaderBar actions={<button>Options</button>}>Chat title</DetailHeaderBar></header>}
        <div style={{ height: 2400 }}>Long content</div>
      </article>
    </AppShell>);
    await frame();
    window.scrollTo(0, 700);
    await frame();
    const header = document.querySelector<HTMLElement>(variant === "page" ? ".page-header" : variant === "detail" ? ".detail-header" : ".ai-header")!;
    const expectedTop = matchMedia("(max-width: 767px)").matches ? 44 : 0;
    assert(window.scrollY > 500, "Page did not scroll");
    assert(Math.abs(header.getBoundingClientRect().top - expectedTop) < 1, variant + " header scrolled offscreen");
    const button = header.querySelector("button")!.getBoundingClientRect();
    assert(button.left >= 0 && button.right <= innerWidth, variant + " actions are outside the viewport");
    assert(button.top >= expectedTop && button.bottom < innerHeight, variant + " actions are not visible");
    window.scrollTo(0, 0);
  }
  document.getElementById("result")!.textContent = "PASS: page, detail and chat headers stay visible while scrolling";
  document.body.dataset.testResult = "passed";
}
void run().catch((error: unknown) => {
  document.getElementById("result")!.textContent = "FAIL: " + String(error);
  document.body.dataset.testResult = "failed";
});

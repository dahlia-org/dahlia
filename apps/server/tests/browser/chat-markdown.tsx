// pnpm dev:client -> /tests/browser/chat-markdown.html. No backend is contacted.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { flushSync } from "react-dom";
import { ChatMarkdown, StreamingChatMarkdown } from "@dahlia-ai/ui/screens/ChatMarkdown";
import "@dahlia-ai/ui/styles.css";
const content = `直近は**2026年9月28日**に次のミーティングがありました。

## 最近のミーティング

- **17:00｜月次レビュー**：次のリリースの方針を確認しました。
  - *担当者と期限*を決定しました。
- **16:00｜契約更新**：更新手続きを確認しました。

| 時間 | ミーティング | 状況 |
| --- | --- | --- |
| 17:00 | 月次レビュー | 完了 |
| 16:00 | 契約更新 | 確認中 |

> 詳細は[会議の記録](/o/example)で確認できます。

- [x] 記録を確認
- [ ] 次回の日程を決める

\`meeting_id\` で検索できます。

\`\`\`sql
SELECT meeting_id, name, created_at FROM meetings ORDER BY created_at DESC LIMIT 10;
\`\`\`
`;
flushSync(() => createRoot(document.getElementById("root")!).render(<main style={{ width: "min(720px, calc(100% - 32px))", margin: "32px auto" }}><article className="ai-message assistant"><ChatMarkdown content={content} /></article></main>));
requestAnimationFrame(() => {
  const result = document.getElementById("result")!;
  const code = document.querySelector("pre code")!;
  const list = document.querySelector(".chat-markdown ul")!;
  const ok = document.querySelector("strong")?.textContent === "2026年9月28日"
    && getComputedStyle(list).listStyleType === "disc"
    && getComputedStyle(code).whiteSpace === "pre"
    && document.documentElement.scrollWidth <= innerWidth;
  result.textContent = ok ? "PASS: Markdown structure, list markers, code whitespace and bounded layout" : "FAIL: Markdown layout";
});

async function checkStreaming() {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  const render = (content: string) => flushSync(() => root.render(<StrictMode><StreamingChatMarkdown content={content} /></StrictMode>));
  const assert = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const until = async (test: () => boolean) => {
    const deadline = performance.now() + 5000;
    while (!test()) { if (performance.now() > deadline) throw new Error("Streaming projection timed out"); await new Promise(requestAnimationFrame); }
  };
  render("**first**");
  render("**second**");
  render("**latest**");
  assert(host.querySelector("strong")?.textContent === "first", "Each chunk reparsed Markdown immediately");
  await until(() => host.querySelector("strong")?.textContent === "latest");
  render("**pending**");
  flushSync(() => root.render(<ChatMarkdown content="**complete response**" />));
  assert(host.querySelector("strong")?.textContent === "complete response", "Completion lost pending content");
  render("**next stream**");
  render("**next latest**");
  await until(() => host.querySelector("strong")?.textContent === "next latest");
  root.unmount(); host.remove();
  const result = document.getElementById("result")!;
  assert(!result.textContent?.startsWith("FAIL"), "Markdown layout failed");
  result.textContent = "PASS: Markdown layout, coalesced stream, latest content, completion and stream replacement";
}
void checkStreaming().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });

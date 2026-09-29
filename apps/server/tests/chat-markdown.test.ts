import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { ChatMarkdown } from "../src/client/ChatMarkdown";

const render = (content: string) => renderToStaticMarkup(createElement(ChatMarkdown, { content }));
describe("chat Markdown", () => {
  it("renders Japanese replies, nested lists, headings, links and code", () => {
    const html = render('## 直近の会議\n\n**2026年9月28日**の会議です。\n\n- **17:00** レビュー\n  - *確認事項*\n\n1. [会議を開く](/o/example)\n\n> 引用\n\n`inline`\n\n```sql\nSELECT * FROM meetings;\n```');
    for (const value of ['<h2>直近の会議</h2>', '<strong>17:00</strong>', '<ul>', '<ol>', '<em>確認事項</em>', 'href="/o/example"', '<blockquote>', '<pre><code class="language-sql">']) expect(html).toContain(value);
  });
  it("supports GFM tables, strikethrough and disabled task checkboxes", () => {
    const html = render('| 時間 | 会議 |\n| --- | --- |\n| 17:00 | レビュー |\n\n~~完了~~\n\n- [x] 確認');
    expect(html).toContain('<table>');
    expect(html).toContain('<th>時間</th>');
    expect(html).toContain('<del>完了</del>');
    expect(html).toContain('type="checkbox" disabled="" checked=""');
  });
  it("does not execute HTML, unsafe links or auto-load remote images", () => {
    const html = render('<script>alert(1)</script>\n\n<img src="x" onerror="alert(1)">\n\n[unsafe](javascript:alert%281%29)\n\n![diagram](https://example.com/image.png)');
    expect(html).not.toMatch(/<script|<img|onerror|href="javascript:/);
    expect(html).toContain('<a href="https://example.com/image.png">diagram</a>');
  });
  it("renders an incomplete streamed code fence and its completed form", () => {
    expect(render('**回答**\n\n```sql\nSELECT')).toContain('<pre><code class="language-sql">SELECT');
    expect(render('**回答**\n\n```sql\nSELECT 1;\n```')).toContain('SELECT 1;');
  });
});

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, it, vi } from "vitest";
import { NotesStatus } from "../src/client/Documents";
import { DetailHeaderBar } from "../src/client/layout/AppShell";

it("keeps a long Notes failure out of the header and page layout until opened", () => {
  const error = "Server could not synchronize this document. ".repeat(30);
  const retry = vi.fn();
  const html = renderToStaticMarkup(createElement(DetailHeaderBar, {
    children: "Meeting",
    actions: createElement(NotesStatus, { status: "Not synced", error, retry }),
  }));
  expect(html).toContain("Not synced");
  expect(html).toContain('aria-haspopup="dialog"');
  expect(html).toContain('aria-expanded="false"');
  expect(html).not.toContain(error);
  expect(html).not.toContain('role="alert"');
  expect(retry).not.toHaveBeenCalled();
});

it("shows normal synchronization status without a warning control", () => {
  const html = renderToStaticMarkup(createElement(NotesStatus, { status: "Synced" }));
  expect(html).toBe("<span>Synced</span>");
});

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, it, vi } from "vitest";
import { ServerSummarySettings } from "../src/client/SummaryGeneration";
import { useLiveJSON } from "../src/client/live-data";
import { modelList } from "../src/ai-gateway/models";

vi.mock("../src/client/live-data", () => ({ useLiveJSON: vi.fn(), refreshData: vi.fn() }));
vi.mock("../src/client/api", () => ({ json: vi.fn(), uiText: (en: string) => en }));

it.each([false, true])("hides the automatic review alias from summary model choices (alias only: %s)", (aliasOnly) => {
  const catalog = modelList([
    { id: "codex-auto-review" },
    ...aliasOnly ? [] : [{ id: "gpt-5.6-terra" }],
  ]);
  vi.mocked(useLiveJSON).mockImplementation((url) => ({
    data: url === "/api/v1/models" ? catalog
      : url === "/api/v1/capabilities" ? { summaryGeneration: { version: 1, methods: ["transcript"] } }
      : { settings: null },
    loading: false, error: undefined, reload: vi.fn(),
  }));
  const html = renderToStaticMarkup(createElement(ServerSummarySettings));
  expect(catalog.data.some(({ id }) => id === "codex-auto-review")).toBe(true);
  expect(html).not.toContain('value="codex-auto-review"');
  if (aliasOnly) expect(html).toContain("No models available");
  else expect(html).toContain('value="gpt-5.6-terra"');
});

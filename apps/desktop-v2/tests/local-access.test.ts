import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AuthState, Meeting } from "../src/shared/types.js";
import { App } from "../src/renderer/App.js";
import { MeetingView } from "../src/renderer/MeetingView.js";
import { SettingsModal, SignIn } from "../src/renderer/Modals.js";
import { t } from "../src/renderer/i18n.js";

const mocks = vi.hoisted(() => ({
  live: vi.fn(),
  recorder: {
    active: undefined, error: undefined, starting: false, start: vi.fn(async () => {}), stop: vi.fn(async () => {}),
    levels: { mic: 0, system: 0 }, elapsedMs: 0, systemWarning: undefined,
  },
}));
vi.mock("../src/renderer/capture.js", () => ({ api: {}, useLive: mocks.live, useRecorder: () => mocks.recorder }));

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubGlobal("localStorage", { getItem: () => null });
});
afterEach(() => vi.unstubAllGlobals());

describe("local access without Databricks", () => {
  it.each<AuthState>([{ status: "signedOut" }, { status: "signingIn", workspace: "https://workspace.example.com" }])("keeps meetings visible without a forced sign-in dialog ($status)", (auth) => {
    mocks.live.mockReturnValueOnce(auth).mockReturnValueOnce([{ id: "m", name: "Saved local meeting", createdAt: 0, busy: false }]);
    const html = renderToStaticMarkup(createElement(App));
    expect(html).toContain("Saved local meeting");
    expect(html).toContain(t("newMeeting"));
    expect(html).toContain(t("notSignedIn"));
    expect(html).not.toContain('role="dialog"');
  });

  it("shows local recording and transcript controls alongside the summary sign-in action", () => {
    const meeting: Meeting = {
      id: "m", name: "Saved local meeting", description: "", createdAt: 0, recordings: [],
      segments: [{ id: "s", recordingId: "r", source: "mic", startMs: 0, endMs: 1000, offsetMs: 0, text: "Local transcript" }],
      summary: { status: "failed", error: "auth_signedOut", createdAt: 0 },
    };
    mocks.live.mockReturnValueOnce(meeting).mockReturnValueOnce([]);
    const html = renderToStaticMarkup(createElement(MeetingView, { meetingId: "m", recorder: mocks.recorder, onDeleted: () => {}, onSummarize: () => {} }));
    expect(html).toContain(t("record"));
    expect(html).toContain(t("transcript"));
    expect(html).toContain(t("signIn"));
    expect(html).not.toContain('role="dialog"');
  });

  it("allows transcription settings before sign-in", () => {
    mocks.live.mockReturnValue({ transcriptionLocale: "ja-JP", summaryLanguage: "ja", summaryModel: "system.ai.claude-haiku-5-5" });
    const html = renderToStaticMarkup(createElement(SettingsModal, { auth: undefined, onClose: () => {} }));
    expect(html).toContain(t("transcriptionLanguage"));
    expect(html).toContain("ja-JP");
    expect(html).toContain(t("notSignedIn"));
  });

  it("offers a close action even before a sign-in attempt starts", () => {
    const html = renderToStaticMarkup(createElement(SignIn, { auth: { status: "signedOut" }, onClose: () => {} }));
    expect(html).toContain(`aria-label="${t("close")}"`);
  });
});

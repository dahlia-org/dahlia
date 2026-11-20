import { EventEmitter } from "node:events";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Credential } from "../src/main/oauth.js";
import type { ActiveRecording, Meeting, RecordingState } from "../src/shared/types.js";

const mocks = vi.hoisted(() => ({
  electron: Object.create(null) as Record<string, unknown>,
  fsync: vi.fn(),
  signIn: vi.fn(),
  processor: { recover: vi.fn(), enqueueTranscription: vi.fn(), isBusy: () => false, stop: vi.fn() },
}));
vi.mock("electron", () => mocks.electron);
vi.mock("node:fs", async (original) => ({ ...await original<typeof import("node:fs")>(), fsyncSync: mocks.fsync }));
vi.mock("../src/main/oauth.js", async (original) => ({ ...await original<typeof import("../src/main/oauth.js")>(), signIn: mocks.signIn }));
vi.mock("../src/main/processing.js", () => ({ Processor: class { constructor() { return mocks.processor; } } }));

let app: EventEmitter & { quit: ReturnType<typeof vi.fn> };
let contents: EventEmitter & { send: ReturnType<typeof vi.fn> };
let directory: string;
let handlers: Map<string, (...args: unknown[]) => unknown>;
let ipc: EventEmitter;
const flush = async () => { for (let index = 0; index < 10; index++) await Promise.resolve(); };
const invoke = <T>(name: string, ...args: unknown[]) => handlers.get(name)!({ sender: contents, senderFrame: { url: "app://dahlia/" } }, ...args) as T;

beforeEach(async () => {
  vi.resetModules();
  vi.clearAllMocks();
  directory = mkdtempSync(join(tmpdir(), "dahlia-v2-main-"));
  handlers = new Map();
  app = Object.assign(new EventEmitter(), {
    quit: vi.fn(), setName: vi.fn(), setPath: vi.fn(), getPath: (name: string) => name === "userData" ? join(directory, "dahlia-v2") : directory,
    requestSingleInstanceLock: () => true, getLocale: () => "en", whenReady: () => Promise.resolve(),
    getAppPath: () => directory,
  });
  contents = Object.assign(new EventEmitter(), { send: vi.fn(), setWindowOpenHandler: vi.fn() });
  class Window extends EventEmitter {
    webContents = contents;
    loadURL = vi.fn();
    show = vi.fn();
    hide = vi.fn();
  }
  ipc = Object.assign(new EventEmitter(), { handle: (name: string, handler: (...args: unknown[]) => unknown) => handlers.set(name, handler) });
  Object.assign(mocks.electron, {
    app, BrowserWindow: Window, ipcMain: ipc,
    dialog: { showMessageBoxSync: () => 1 },
    protocol: { registerSchemesAsPrivileged: vi.fn(), handle: vi.fn() },
    session: { defaultSession: { setPermissionRequestHandler: vi.fn(), setPermissionCheckHandler: vi.fn(), setDisplayMediaRequestHandler: vi.fn() } },
    Menu: { buildFromTemplate: vi.fn(), setApplicationMenu: vi.fn() },
    systemPreferences: { getMediaAccessStatus: () => "granted" },
    safeStorage: { encryptString: (value: string) => Buffer.from(value) },
    shell: { openExternal: vi.fn() }, net: {}, desktopCapturer: {},
  });
  mocks.fsync.mockImplementation((await vi.importActual<typeof import("node:fs")>("node:fs")).fsyncSync);
  await import("../src/main/main.js");
  await flush();
});

afterEach(() => {
  const state = invoke<RecordingState>("recording:state");
  if (state.active) invoke("recording:stop", state.active.recordingId);
  app.emit("will-quit");
  vi.useRealTimers();
});

async function record() {
  const meeting = invoke<string>("meetings:create");
  const active = await invoke<Promise<ActiveRecording>>("recording:start", meeting);
  ipc.emit("recording:append", { sender: contents, senderFrame: { url: "app://dahlia/" } }, active.recordingId, "mic", new Uint8Array(32_000));
  return active;
}

describe("recording lifecycle", () => {
  it("waits for the renderer to drain capture before quitting", async () => {
    const active = await record();
    const event = { preventDefault: vi.fn() };
    app.emit("before-quit", event);
    expect(event.preventDefault).toHaveBeenCalled();
    expect(contents.send).toHaveBeenCalledWith("recording:request-stop");
    expect(app.quit).not.toHaveBeenCalled();
    expect(invoke<RecordingState>("recording:state").active).toEqual(active);
    // The renderer's final partial chunk arrives before its stop acknowledgement.
    ipc.emit("recording:append", { sender: contents, senderFrame: { url: "app://dahlia/" } }, active.recordingId, "mic", new Uint8Array(16_000));
    invoke("recording:stop", active.recordingId);
    expect(invoke<Meeting>("meetings:get", active.meetingId).recordings[0]?.durationMs).toBe(1500);
    expect(app.quit).toHaveBeenCalledOnce();
  });

  it("keeps saved audio when close fails", async () => {
    const active = await record();
    mocks.fsync.mockImplementationOnce(() => { throw new Error("EIO"); });
    invoke("recording:stop", active.recordingId);
    expect(invoke<RecordingState>("recording:state")).toEqual({ error: "writeFailed", active: undefined });
    expect(invoke<Meeting>("meetings:get", active.meetingId).recordings[0]?.durationMs).toBe(1000);
    expect(readFileSync(join(directory, "dahlia-v2", "recordings", active.meetingId, active.recordingId, "mic.pcm"))).toHaveLength(32_000);
  });

  it("preserves uncertain empty files on failure but removes a successful empty recording", async () => {
    const meeting = invoke<string>("meetings:create");
    const active = await invoke<Promise<ActiveRecording>>("recording:start", meeting);
    mocks.fsync.mockImplementationOnce(() => { throw new Error("EIO"); });
    invoke("recording:stop", active.recordingId);
    expect(invoke<Meeting>("meetings:get", meeting).recordings[0]?.status).toBe("failed");
    expect(existsSync(join(directory, "dahlia-v2", "recordings", meeting, active.recordingId))).toBe(true);
    const empty = await invoke<Promise<ActiveRecording>>("recording:start", meeting);
    invoke("recording:stop", empty.recordingId);
    expect(invoke<Meeting>("meetings:get", meeting).recordings).toHaveLength(1);
  });

  it("visibly stops on periodic flush failure and keeps saved audio", async () => {
    vi.useFakeTimers();
    const active = await record();
    mocks.fsync.mockImplementationOnce(() => { throw new Error("EIO"); });
    vi.advanceTimersByTime(5000);
    expect(invoke<RecordingState>("recording:state").error).toBe("writeFailed");
    expect(invoke<RecordingState>("recording:state").active).toBeUndefined();
    expect(invoke<Meeting>("meetings:get", active.meetingId).recordings[0]?.durationMs).toBe(1000);
  });
});

describe("sign-in adoption", () => {
  it("rejects a cancelled/replaced attempt even if its provider resolves late", async () => {
    const first = Promise.withResolvers<Credential>();
    const second = Promise.withResolvers<Credential>();
    mocks.signIn.mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise);
    invoke("auth:signIn", "https://one.example.com");
    invoke("auth:cancelSignIn");
    invoke("auth:signIn", "https://two.example.com");
    const credential: Credential = { workspace: "https://one.example.com", email: "one@example.com", accessToken: "t", refreshToken: "r", expiresAt: Date.now() + 100_000, tokenEndpoint: "https://one.example.com/token" };
    first.resolve(credential);
    await flush();
    expect(invoke("auth:state")).toMatchObject({ status: "signingIn", workspace: "https://two.example.com" });
    second.resolve({ ...credential, workspace: "https://two.example.com" });
    await flush();
    expect(invoke("auth:state")).toMatchObject({ status: "signedIn", workspace: "https://two.example.com" });
  });
});

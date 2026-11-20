// Dahlia v2's main process: the window, the database, recording files, sign-in and the processing queue. The renderer
// reaches these only through the preload's operations, each checked here for its sender and input.
import { app, BrowserWindow, desktopCapturer, dialog, ipcMain, Menu, net, protocol, safeStorage, session, shell, systemPreferences, type IpcMainEvent, type IpcMainInvokeEvent } from "electron";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { ActiveRecording, AuthState, Settings } from "../shared/types.js";
import { Database } from "./db.js";
import { SignInError, signIn, TokenSource, type Credential } from "./oauth.js";
import * as policy from "./policy.js";
import { Processor } from "./processing.js";
import { RecordingWriter, recordingDirectory, recoveredDurationMs, removeMeetingAudio } from "./recorder.js";
import { listModels } from "./summary.js";
import { listLocales } from "./transcriber.js";

const here = dirname(fileURLToPath(import.meta.url));
const developmentRenderer = app.isPackaged ? undefined : process.env.DAHLIA_V2_RENDERER_URL;
const developmentOrigin = developmentRenderer ? new URL(developmentRenderer).origin : undefined;

// Its own identity and data, apart from Dahlia for macOS and the alpha.
app.setName("Dahlia v2");
app.setPath("userData", join(app.getPath("appData"), "dahlia-v2"));
protocol.registerSchemesAsPrivileged([{ scheme: "app", privileges: { standard: true, secure: true, supportFetchAPI: true } }]);

// Two instances would write the same database and recording files.
if (!app.requestSingleInstanceLock()) app.exit(0);

const dataDirectory = app.getPath("userData");
const recordingsRoot = join(dataDirectory, "recordings");
const credentialFile = join(dataDirectory, "credential.bin");
const helper = app.isPackaged
  ? join(process.resourcesPath, "..", "MacOS", "dahlia-transcribe")
  : join(app.getAppPath(), "native", ".build", "release", "dahlia-transcribe");

let mainWindow: BrowserWindow | undefined;
let quitting = false;
let quitAfterRecording = false;
let db: Database;
let processor: Processor;
let tokens: TokenSource;
let signingIn: { workspace: string; controller: AbortController } | undefined;
let signInError: string | undefined;
let writer: { active: ActiveRecording; file: RecordingWriter } | undefined;
let recordingError: string | undefined;
let locales: Promise<string[]> | undefined;

const notify = () => mainWindow?.webContents.send("changed");

function loadCredential(): Credential | undefined {
  try {
    return JSON.parse(safeStorage.decryptString(readFileSync(credentialFile))) as Credential;
  } catch {
    return undefined;
  }
}

function saveCredential(credential: Credential | undefined) {
  if (!credential) return rmSync(credentialFile, { force: true });
  // Encrypted with a key macOS keeps in the Keychain for this app.
  writeFileSync(credentialFile, safeStorage.encryptString(JSON.stringify(credential)), { mode: 0o600 });
}

function authState(): AuthState {
  if (signingIn) return { status: "signingIn", workspace: signingIn.workspace };
  const credential = tokens.current;
  return credential ? { status: "signedIn", workspace: credential.workspace, email: credential.email } : { status: "signedOut", error: signInError };
}

/** Closes the open recording and queues its transcription; a recording without audio is removed. */
function finishRecording(error?: string) {
  if (!writer) return;
  const { active, file } = writer;
  writer = undefined;
  recordingError = error;
  let durationMs: number;
  try {
    durationMs = file.close();
  } catch {
    recordingError ??= "writeFailed";
    try { durationMs = recoveredDurationMs(file.directory); } catch { durationMs = 0; }
  }
  if (durationMs > 0) {
    db.finishRecording(active.recordingId, durationMs);
    processor.enqueueTranscription(active.recordingId);
  } else if (recordingError) {
    // Failure is not evidence of an empty recording. Leave its files available for recovery/retry.
    db.setRecordingStatus(active.recordingId, "failed", recordingError);
  } else {
    rmSync(file.directory, { recursive: true, force: true });
    db.deleteRecording(active.recordingId);
  }
  notify();
  if (quitAfterRecording) {
    quitting = true;
    app.quit();
  }
}

function handle<T extends unknown[]>(channel: string, listener: (...args: T) => unknown) {
  ipcMain.handle(channel, (event: IpcMainInvokeEvent, ...args: unknown[]) => {
    assertSender(event);
    return listener(...(args as T));
  });
}

function assertSender(event: IpcMainInvokeEvent | IpcMainEvent) {
  if (!mainWindow || event.sender !== mainWindow.webContents || !event.senderFrame || !policy.isAppUrl(event.senderFrame.url, developmentOrigin)) {
    throw new Error("Untrusted sender");
  }
}

function registerIPC() {
  handle("auth:state", () => authState());
  handle("auth:signIn", (input: unknown) => {
    const workspace = policy.workspaceInput(input);
    signingIn?.controller.abort();
    const controller = new AbortController();
    signingIn = { workspace, controller };
    signInError = undefined;
    notify();
    signIn(workspace, (url) => shell.openExternal(url), controller.signal)
      .then((credential) => {
        if (signingIn?.controller === controller && !controller.signal.aborted) tokens.set(credential);
      })
      .catch((error: unknown) => {
        if (signingIn?.controller === controller) signInError = error instanceof SignInError ? error.message : "failed";
      })
      .finally(() => {
        if (signingIn?.controller === controller) signingIn = undefined;
        notify();
      });
  });
  handle("auth:cancelSignIn", () => signingIn?.controller.abort());
  handle("auth:signOut", () => {
    signingIn?.controller.abort();
    signingIn = undefined;
    tokens.set(undefined);
    signInError = undefined;
    notify();
  });

  handle("meetings:list", () => db.listMeetings());
  handle("meetings:get", (meetingId: unknown) => db.getMeeting(policy.id(meetingId)));
  handle("meetings:create", () => {
    const meetingId = db.createMeeting(new Intl.DateTimeFormat(app.getLocale(), { dateStyle: "medium", timeStyle: "short" }).format(new Date()));
    notify();
    return meetingId;
  });
  handle("meetings:rename", (meetingId: unknown, name: unknown) => {
    db.renameMeeting(policy.id(meetingId), policy.meetingName(name));
    notify();
  });
  handle("meetings:delete", (input: unknown) => {
    const meetingId = policy.id(input);
    if (writer?.active.meetingId === meetingId || processor.isBusy(meetingId)) throw new Error("busy");
    db.deleteMeeting(meetingId);
    removeMeetingAudio(recordingsRoot, meetingId);
    notify();
  });

  handle("recording:state", () => ({ active: writer?.active, error: recordingError }));
  handle("recording:start", async (input: unknown) => {
    const meetingId = policy.id(input);
    if (writer) throw new Error("alreadyRecording");
    if (!db.getMeeting(meetingId)) throw new Error("Unknown meeting");
    if (systemPreferences.getMediaAccessStatus("microphone") !== "granted" && !(await systemPreferences.askForMediaAccess("microphone"))) {
      throw new Error("microphoneDenied");
    }
    if (writer) throw new Error("alreadyRecording");
    // No sign-in check: recording works offline and with an expired token.
    const recording = db.startRecording(meetingId, db.settings().transcriptionLocale);
    const active = { meetingId, recordingId: recording.id, startedAt: recording.startedAt };
    try {
      writer = { active, file: new RecordingWriter(recording.id, recordingDirectory(recordingsRoot, meetingId, recording.id), () => finishRecording("writeFailed")) };
    } catch {
      db.setRecordingStatus(recording.id, "failed", "writeFailed");
      recordingError = "writeFailed";
      notify();
      throw new Error("writeFailed");
    }
    recordingError = undefined;
    notify();
    return active;
  });
  ipcMain.on("recording:append", (event, recordingId: unknown, source: unknown, chunk: unknown) => {
    try {
      assertSender(event);
    } catch {
      return;
    }
    if (!writer || writer.active.recordingId !== recordingId || !(chunk instanceof ArrayBuffer || chunk instanceof Uint8Array)) return;
    try {
      writer.file.append(policy.source(source), chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk));
    } catch {
      // The disk refused the audio: stop now and keep what was written, rather than drop audio silently.
      finishRecording("writeFailed");
    }
  });
  handle("recording:stop", (recordingId: unknown, error: unknown) => {
    if (error !== undefined && error !== "captureEnded" && error !== "captureFailed") throw new Error("Invalid recording error");
    if (writer?.active.recordingId === policy.id(recordingId)) finishRecording(error);
  });

  handle("processing:retranscribe", (meetingId: unknown) => processor.retranscribe(policy.id(meetingId)));
  handle("processing:summarize", (input: unknown) => {
    const meetingId = policy.id(input);
    if (!processor.isBusy(meetingId)) processor.enqueueSummary(meetingId);
  });
  handle("processing:progress", () => processor.progressList());

  handle("settings:get", () => db.settings());
  handle("settings:set", (patch: unknown) => {
    for (const [key, value] of Object.entries(policy.settingsPatch(patch))) db.setSetting(key as keyof Settings, value);
    notify();
    return db.settings();
  });
  handle("settings:models", async () => {
    const current = db.settings().summaryModel;
    try {
      const { workspace, token } = await tokens.token();
      const models = await listModels(workspace, token, AbortSignal.timeout(30_000));
      return models.includes(current) ? models : [current, ...models];
    } catch {
      return [current];
    }
  });
  handle("settings:locales", async () => {
    locales ??= listLocales(helper, AbortSignal.timeout(60_000)).catch(() => {
      locales = undefined;
      return [];
    });
    return locales;
  });
}

function configureSession() {
  const ses = session.defaultSession;
  const fromWindow = (contents: Electron.WebContents | null | undefined) => Boolean(mainWindow && contents === mainWindow.webContents);
  // The microphone and the system audio loopback, for this mainWindow only. Everything else is denied.
  ses.setPermissionRequestHandler((contents, permission, callback, details) => {
    callback(fromWindow(contents) && (permission === "media" || permission === "display-capture") && policy.isAppUrl(details.requestingUrl, developmentOrigin));
  });
  ses.setPermissionCheckHandler((contents, permission, origin) =>
    fromWindow(contents) && (permission === "media" || permission === "display-capture") && policy.isAppUrl(origin, developmentOrigin));
  // getDisplayMedia returns the screen (stopped at once by the renderer) and the Mac's audio output. macOS records it
  // with a CoreAudio tap, which needs NSAudioCaptureUsageDescription; without the permission the track is silent.
  ses.setDisplayMediaRequestHandler((request, callback) => {
    if (!mainWindow || request.frame?.url === undefined || !policy.isAppUrl(request.frame.url, developmentOrigin)) return callback({});
    desktopCapturer.getSources({ types: ["screen"] })
      .then((sources) => callback(sources[0] ? { video: sources[0], audio: "loopback" } : {}))
      .catch(() => callback({}));
  });
  protocol.handle("app", (request) => {
    const { host, pathname } = new URL(request.url);
    if (host !== "dahlia") return new Response(null, { status: 404 });
    const file = policy.rendererFile(join(here, "renderer"), pathname, join);
    return net.fetch(pathToFileURL(file).href).then((response) => {
      const headers = new Headers(response.headers);
      headers.set("content-security-policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
      return new Response(response.body, { status: response.status, headers });
    });
  });
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 760,
    minHeight: 480,
    title: "Dahlia v2",
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 14, y: 10 },
    vibrancy: "sidebar",
    visualEffectState: "followWindow",
    backgroundColor: "#00000000",
    show: false,
    webPreferences: {
      preload: join(here, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      // Capture runs in this page; a hidden mainWindow must keep recording.
      backgroundThrottling: false,
    },
  });
  const contents = mainWindow.webContents;
  contents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//.test(url)) void shell.openExternal(url);
    return { action: "deny" };
  });
  contents.on("will-navigate", (event, url) => {
    if (!policy.isAppUrl(url, developmentOrigin)) event.preventDefault();
  });
  contents.on("will-attach-webview", (event) => event.preventDefault());
  // A reloaded or crashed page has lost its capture; close the recording with what was written.
  contents.on("did-start-loading", () => finishRecording("rendererGone"));
  contents.on("render-process-gone", () => finishRecording("rendererGone"));
  mainWindow.once("ready-to-show", () => mainWindow?.show());
  // Closing hides the mainWindow, so a recording continues until it is stopped or the app quits.
  mainWindow.on("close", (event) => {
    if (!quitting) {
      event.preventDefault();
      mainWindow?.hide();
    }
  });
  void mainWindow.loadURL(developmentRenderer ?? `${policy.appOrigin}/`);
}

function buildMenu() {
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { role: "appMenu" },
    { role: "editMenu" },
    { label: "View", submenu: [{ role: "resetZoom" }, { role: "zoomIn" }, { role: "zoomOut" }, { type: "separator" }, { role: "togglefullscreen" }, ...(app.isPackaged ? [] : [{ role: "toggleDevTools" } as const])] },
    { role: "windowMenu" },
  ]));
}

app.on("second-instance", () => mainWindow?.show());
app.on("activate", () => mainWindow?.show());
app.on("before-quit", (event) => {
  if (writer && !quitting) {
    event.preventDefault();
    if (quitAfterRecording) return;
    const choice = dialog.showMessageBoxSync({
      type: "warning",
      buttons: app.getLocale().startsWith("ja") ? ["キャンセル", "録音を停止して終了"] : ["Cancel", "Stop Recording and Quit"],
      defaultId: 0,
      cancelId: 0,
      message: app.getLocale().startsWith("ja") ? "録音中です。終了すると録音を停止します。" : "Recording is in progress. Quitting stops it.",
    });
    if (choice === 0) return;
    quitAfterRecording = true;
    mainWindow?.webContents.send("recording:request-stop");
    return;
  }
  quitting = true;
  processor?.stop();
});
app.on("will-quit", () => db?.close());

void app.whenReady().then(() => {
  mkdirSync(recordingsRoot, { recursive: true, mode: 0o700 });
  db = new Database(join(dataDirectory, "dahlia-v2.sqlite"));
  tokens = new TokenSource(existsSync(credentialFile) ? loadCredential() : undefined, saveCredential);
  processor = new Processor({ db, recordingsRoot, helper, token: () => tokens.token(), notify });
  processor.recover();
  configureSession();
  registerIPC();
  buildMenu();
  createWindow();
});

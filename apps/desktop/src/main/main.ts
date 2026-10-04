import { app, BrowserWindow, dialog, ipcMain, net, protocol, session, shell, type IpcMainInvokeEvent, type Session } from "electron";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { appOrigin, callbackPath, externalURL, isServerPath, relayAllowed, rendererFile, serverOrigin, signInCompleted } from "./policy";

// Independent identity and storage from the Swift app (com.dahlia.app): cookies and Web storage live here.
app.setName("Dahlia Alpha");
app.setPath("userData", join(app.getPath("appData"), "Dahlia Alpha"));

const server = serverOrigin(process.env.DAHLIA_SERVER_URL);
const developmentRenderer = process.env.DAHLIA_DESKTOP_RENDERER_URL;
const rendererRoot = join(app.getAppPath(), "dist", "renderer");
const csp = [
  "default-src 'self'",
  `script-src 'self'${developmentRenderer ? " 'unsafe-inline'" : ""}`,
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https:",
  "font-src 'self' data:",
  `connect-src 'self'${developmentRenderer ? ` ${developmentRenderer.replace(/^http/, "ws")}` : ""}`,
  "worker-src 'self' blob:",
  "object-src 'none'",
  "base-uri 'none'",
  "frame-ancestors 'none'",
].join("; ");

protocol.registerSchemesAsPrivileged([{ scheme: "app", privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true } }]);

let mainWindow: BrowserWindow | undefined;
let serverSession: Session;

// The Server session holds the browser session cookie. Only this relay and the sign-in window use it,
// so pages loaded during sign-in can never reach app:// and the renderer never sees the cookie.
async function relay(request: Request, url: URL): Promise<Response> {
  if (!relayAllowed(request.headers.get("origin"))) return new Response(null, { status: 403 });
  const headers = new Headers(request.headers);
  for (const name of ["cookie", "host", "origin", "referer"]) headers.delete(name);
  // Mutations carry the Server origin, as the same-origin Web client does; the Server still checks the session.
  if (!["GET", "HEAD"].includes(request.method)) headers.set("origin", server);
  const upstream = new AbortController();
  try {
    const response = await serverSession.fetch(new URL(`${url.pathname}${url.search}`, server).href, {
      method: request.method,
      headers,
      body: ["GET", "HEAD"].includes(request.method) ? undefined : await request.arrayBuffer(),
      credentials: "include",
      signal: upstream.signal,
    });
    const forwarded = new Headers(response.headers);
    forwarded.delete("set-cookie");
    // Electron cancels the body (not request.signal) when the renderer closes an EventSource or aborts a fetch.
    // Abort the Server request too, or open event streams would exhaust the connection pool.
    const reader = response.body?.getReader();
    const body = reader && new ReadableStream<Uint8Array>({
      async pull(controller) {
        const { done, value } = await reader.read();
        if (done) controller.close(); else controller.enqueue(value);
      },
      cancel() { upstream.abort(); },
    });
    return new Response(body ?? null, { status: response.status, statusText: response.statusText, headers: forwarded });
  } catch {
    // Same failure the Web client sees when the Server is unreachable; nothing is reported as saved.
    return Response.error();
  }
}

async function renderer(request: Request, url: URL): Promise<Response> {
  if (!["GET", "HEAD"].includes(request.method)) return new Response(null, { status: 405 });
  let response: Response;
  if (developmentRenderer) {
    response = await net.fetch(new URL(`${url.pathname}${url.search}`, developmentRenderer).href);
  } else {
    // Files come only from the renderer directory; every other path is an SPA route.
    const file = rendererFile(rendererRoot, url.pathname);
    const asset = file ? await net.fetch(pathToFileURL(file).href).catch(() => undefined) : undefined;
    response = asset?.ok ? asset : await net.fetch(pathToFileURL(join(rendererRoot, "index.html")).href);
  }
  const headers = new Headers(response.headers);
  headers.set("content-security-policy", csp);
  headers.set("x-content-type-options", "nosniff");
  return new Response(response.body, { status: response.status, headers });
}

function trusted(event: IpcMainInvokeEvent): boolean {
  return event.sender === mainWindow?.webContents && event.senderFrame?.url.startsWith(`${appOrigin}/`) === true;
}

function openExternal(url: string) {
  const target = externalURL(url, server);
  if (target) void shell.openExternal(target);
}

/** Runs the Server's own sign-in page in an isolated window; resolves when the Server session is established. */
function signIn(next: string): Promise<boolean> {
  return new Promise((resolve) => {
    const window = new BrowserWindow({
      parent: mainWindow, width: 520, height: 720, title: "Sign in to Dahlia", autoHideMenuBar: true,
      webPreferences: { session: serverSession, sandbox: true, contextIsolation: true, nodeIntegration: false },
    });
    let signedIn = false;
    const follow = async (_event: unknown, url: string) => {
      if (signedIn || !signInCompleted(url, server)) return;
      // Server pages such as the sign-in page's home link are reachable without signing in; require a session.
      const session = await serverSession.fetch(`${server}/api/v1/session`, { credentials: "include" }).catch(() => undefined);
      if (signedIn || !session?.ok) return;
      signedIn = true;
      resolve(true);
      if (!window.isDestroyed()) window.close();
    };
    window.webContents.on("did-navigate", (event, url) => void follow(event, url));
    window.webContents.on("did-redirect-navigation", (event, url) => void follow(event, url));
    window.webContents.setWindowOpenHandler(({ url }) => { openExternal(url); return { action: "deny" }; });
    window.on("closed", () => { if (!signedIn) resolve(false); });
    void window.loadURL(`${server}/sign-in?next=${encodeURIComponent(next)}`);
  });
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280, height: 860, minWidth: 720, minHeight: 480, title: "Dahlia Alpha", show: false,
    webPreferences: {
      preload: join(import.meta.dirname, "preload.cjs"),
      sandbox: true, contextIsolation: true, nodeIntegration: false, webSecurity: true,
    },
  });
  const contents = mainWindow.webContents;
  contents.on("will-navigate", (event, url) => {
    if (url.startsWith(`${appOrigin}/`)) return;
    event.preventDefault();
    openExternal(url);
  });
  contents.on("will-redirect", (event, url) => { if (!url.startsWith(`${appOrigin}/`)) event.preventDefault(); });
  contents.setWindowOpenHandler(({ url }) => { openExternal(url); return { action: "deny" }; });
  contents.on("will-attach-webview", (event) => event.preventDefault());
  // Notes keep unsent edits in memory only; leaving discards them unless the user confirms.
  contents.on("will-prevent-unload", (event) => {
    const ja = app.getLocale().startsWith("ja");
    // Staying is first so Return and Escape both keep the unsent edits.
    const choice = dialog.showMessageBoxSync(mainWindow!, {
      type: "warning", buttons: ja ? ["とどまる", "移動する"] : ["Stay", "Leave"], defaultId: 0, cancelId: 0,
      message: ja ? "ノートに未送信の編集があります。" : "Notes have unsynced changes.",
      detail: ja ? "移動すると、Server に保存されていない編集は失われます。" : "Leaving now discards edits that the Server has not saved.",
    });
    if (choice === 1) event.preventDefault();
  });
  mainWindow.once("ready-to-show", () => mainWindow?.show());
  mainWindow.on("closed", () => { mainWindow = undefined; });
  void mainWindow.loadURL(`${appOrigin}/dashboard`);
}

if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on("second-instance", () => {
    if (!mainWindow) return createWindow();
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  });
  void app.whenReady().then(() => {
    serverSession = session.fromPartition("persist:server");
    for (const target of [session.defaultSession, serverSession]) {
      target.setPermissionRequestHandler((_contents, permission, callback) => callback(permission === "clipboard-sanitized-write"));
    }
    session.defaultSession.protocol.handle("app", (request) => {
      const url = new URL(request.url);
      if (url.host !== "dahlia") return new Response(null, { status: 404 });
      return isServerPath(url.pathname) ? relay(request, url) : renderer(request, url);
    });
    ipcMain.handle("dahlia:config", (event) => {
      if (!trusted(event)) throw new Error("untrusted_sender");
      return { serverOrigin: server };
    });
    ipcMain.handle("dahlia:sign-in", (event, next: unknown) => {
      if (!trusted(event)) throw new Error("untrusted_sender");
      return signIn(callbackPath(next));
    });
    createWindow();
    app.on("activate", () => { if (!BrowserWindow.getAllWindows().length) createWindow(); });
  });
  app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });
}

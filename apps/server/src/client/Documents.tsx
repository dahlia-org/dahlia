import { syncNotifications, type SyncNotifications } from "./sync-notifications";
import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { AlertTriangle } from "lucide-react";
import { Button } from "./components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "./components/ui/popover";
import { EditorContent, useEditor } from "@tiptap/react";
import * as Y from "yjs";
import { apiOperations as api } from "./generated-operations";
import { RequestError, uiText } from "./api";
import { encodeId } from "../typeid";
import { uuidV7 } from "../id";
import { RemoteDocumentSession } from "../documents/remote-session";
import { DocumentSession, type PendingDocumentUpdate } from "../documents/session";
import { DocumentCore, decodeBinary, documentPlainText, encodeBinary, type DocumentBlock, type DocumentRecovery } from "../documents/core";
import { DocumentEditorHydration, documentEditorOptions } from "../documents/editor";
import type { components } from "./generated-api";

type RecoveryBlock = components["schemas"]["DocumentRecovery"]["blocks"][number];
type SharedDocument = NonNullable<components["schemas"]["DocumentEnvelope"]["document"]>;
const sessions = new Map<string, BrowserDocument>();

export class BrowserDocument {
  readonly session: DocumentSession | RemoteDocumentSession;
  private readonly hydration: DocumentEditorHydration;
  readonly editorDocument = new Y.Doc();
  // A lightweight committed replica supports Worker restart without promoting uncommitted editor input.
  private readonly retainedDocument = new Y.Doc();
  readonly pending: PendingDocumentUpdate[] = [];
  readonly recoveries = new Map<string, DocumentRecovery>();
  readonly listeners = new Set<() => void>();
  readonly presenceSession = uuidV7();
  people: string[] = [];
  private bodyError = "";
  private maintenanceError = "";
  private readonly auxiliaryAbort = new AbortController();
  get error() { return this.bodyError || this.maintenanceError; }
  set error(value: string) { this.bodyError = value; }
  private sequence = 0;
  private unsubscribe: (() => void) | undefined;
  private unavailable = false;
  private saving = 0;
  private localSaves: Promise<void> = Promise.resolve();
  private failedEditorUpdate: Uint8Array | null = null;
  private failedEditorText = "";
  private syncing: Promise<void> | null = null;
  private sendTimer: ReturnType<typeof setTimeout> | undefined;
  private syncRequested = false;
  private maintenance: Promise<void> | null = null;
  private recoverySaving: Promise<void> | null = null;
  recoveryOpen = false;
  recoveryNext: string | null = null;
  private recoveryPages: (string | undefined)[] = [];
  private recoveryPage: string | undefined;
  private recoveryRequest = 0;
  private displayedRecoveryIDs = new Set<string>();
  get recoveryPrevious() { return this.recoveryPages.length > 0; }
  async loadRecoveryPage(after?: string) {
    if (!this.session.generation) return;
    const request = ++this.recoveryRequest;
    const generation = this.session.generation;
    const recovered = await api.listDocumentRecoveries({ signal: this.auxiliaryAbort.signal, headers: this.headers,
      params: { ...this.params, query: { after, mode: "display" } } });
    if (request !== this.recoveryRequest || !this.recoveryOpen || generation !== this.session.generation) return;
    for (const id of this.displayedRecoveryIDs) if (!this.unsentRecoveries.has(id)) this.recoveries.delete(id);
    this.displayedRecoveryIDs = new Set(recovered.items.map((entry) => entry.id));
    for (const entry of recovered.items) this.recoveries.set(entry.id, entry);
    this.recoveryPage = after; this.recoveryNext = recovered.nextCursor; this.changed();
  }
  async nextRecoveryPage() {
    if (!this.recoveryNext) return;
    const previous = this.recoveryPage; await this.loadRecoveryPage(this.recoveryNext); this.recoveryPages.push(previous); this.changed();
  }
  async previousRecoveryPage() {
    if (!this.recoveryPages.length) return;
    await this.loadRecoveryPage(this.recoveryPages.at(-1)); this.recoveryPages.pop(); this.changed();
  }
  async toggleRecoveries(open: boolean) {
    this.recoveryOpen = open; ++this.recoveryRequest;
    if (open) { this.recoveryPages = []; await this.loadRecoveryPage(); }
    else {
      for (const id of this.displayedRecoveryIDs) if (!this.unsentRecoveries.has(id)) this.recoveries.delete(id);
      this.displayedRecoveryIDs.clear(); this.changed();
    }
  }
  private views = 0;
  private stopped = false;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private readonly unsentRecoveries = new Set<string>();
  private lastPresence = 0;
  focused = false;
  readonly params: { path: { workspaceId: string; documentId: string } };

  constructor(readonly userId: string, workspaceId: string, readonly meetingId: string, initial: SharedDocument | null, private readonly accountBinding = false, private readonly notifications: SyncNotifications = syncNotifications) {
    this.params = { path: { workspaceId, documentId: initial?.id ?? encodeId("document", uuidV7()) } };
    if (initial) { const update = decodeBinary(initial.checkpoint); Y.applyUpdate(this.editorDocument, update, "remote"); Y.applyUpdate(this.retainedDocument, update); }
    this.hydration = new DocumentEditorHydration(this.editorDocument, this.preserveEditorRecovery);
    this.session = new (typeof Worker === "undefined" ? DocumentSession : RemoteDocumentSession)({
      newID: () => encodeId("documentRecovery", uuidV7()),
      snapshot: () => encodeBinary(Y.encodeStateAsUpdate(this.retainedDocument)),
      append: (update, local, recovery) => {
        Y.applyUpdate(this.retainedDocument, decodeBinary(update, Infinity));
        const sequence = ++this.sequence;
        if (local) this.pending.push({ sequence, update });
        if (recovery) {
          const id = recovery.id.startsWith("drec_") ? recovery.id : encodeId("documentRecovery", recovery.id);
          this.recoveries.set(id, { ...recovery, id }); this.unsentRecoveries.add(id);
        }
        this.changed(); return Promise.resolve(sequence);
      },
      pending: () => Promise.resolve([...this.pending]),
      acknowledge: (through) => {
        const firstUnacknowledged = this.pending.findIndex((item) => item.sequence > through);
        this.pending.splice(0, firstUnacknowledged < 0 ? this.pending.length : firstUnacknowledged);
        this.changed(); return Promise.resolve();
      },
      checkpoint: ({ update, vector }) => {
        this.hydration.receive(decodeBinary(update, Infinity), decodeBinary(vector));
        this.changed(); return Promise.resolve();
      },
      exchange: async (request) => {
        // A retained tab must never submit one account's unsent content after account switching.
        if (!this.accountBinding && (await api.getSession({})).user.id !== this.userId) throw new Error(uiText("Sign in with the original account to sync these edits.", "この編集を同期するには、元のアカウントでサインインしてください。"));
        let generation = request.generation;
        if (!generation) {
          const response = request.update
            ? await api.initializeMeetingNotes({ headers: this.headers, params: { path: { workspaceId, meetingId } }, body: { id: this.params.path.documentId } }, false)
            : await api.getMeetingNotes({ headers: this.headers, params: { path: { workspaceId, meetingId } } });
          if (!response.document) return { generation: null, revision: 0, update: "AAA=" };
          this.params.path.documentId = response.document.id;
          generation = response.document.generation;
        }
        try {
          return await api.exchangeDocument({ headers: this.headers, params: this.params, body: { ...request, protocolVersion: 3, generation } }, false);
        } catch (error) {
          if (!(error instanceof RequestError) || error.status !== 409 || error.message !== "document_generation_changed") throw error;
          const { document } = await api.getDocument({ headers: this.headers, params: this.params });
          if (!document) throw error;
          return { generation: document.generation, revision: document.revision, update: document.checkpoint, refreshed: true };
        }
      },
    }, { checkpoint: initial?.checkpoint, generation: initial?.generation ?? null, revision: initial?.revision ?? 0 });
    this.scheduleFallback();
    window.addEventListener("beforeunload", this.beforeUnload);
  }
  private scheduleFallback() {
    this.timer = setTimeout(() => {
      if (this.stopped) return;
      if (this.hasUnsent() || !this.views || (!this.unavailable && !this.notifications.connected)) void this.sync().catch(() => {});
      if (this.views) void this.refreshMaintenance().catch(() => {});
      this.scheduleFallback();
    }, 2_000);
  }
  private get headers() { return { "X-Dahlia-Document-User": this.userId }; }
  private subscribe() {
    if (this.unsubscribe) return;
    this.unsubscribe = this.notifications.subscribeNotes(this.userId, this.params.path.workspaceId, this.meetingId, (hint) => {
      if (hint?.unavailable) {
        this.unavailable = true; this.error = uiText("These Notes are no longer available.", "このノートにはアクセスできなくなりました。"); this.changed(); return;
      }
      if (!hint || (hint.cursor !== "absent" && hint.cursor !== `${this.session.generation}:${this.session.revision}`)) this.requestSync();
    });
    this.unavailable = false;
  }
  private resumeSubscription() {
    if (this.stopped || !this.views || !this.unavailable) return;
    // An unavailable hint removed the tab owner's target; a successful authorized
    // sync can rearm it only while this document still has a visible owner.
    this.unsubscribe?.(); this.unsubscribe = undefined;
    this.subscribe();
  }
  private beforeUnload = (event: BeforeUnloadEvent) => {
    if (this.hasUnsent()) { event.preventDefault(); event.returnValue = ""; }
  };
  private changed() { for (const listener of this.listeners) listener(); }
  hasUnsent() { return this.saving > 0 || this.failedEditorUpdate !== null || this.pending.length > 0 || this.unsentRecoveries.size > 0; }
  copyText() { return this.failedEditorUpdate ? this.failedEditorText : documentPlainText(this.editorDocument); }
  editFromEditor(update: Uint8Array) { return this.edit(this.hydration.captureLocalUpdate(update), true); }
  preserveEditorRecovery = (blocks: DocumentBlock[]) => {
    const id = encodeId("documentRecovery", uuidV7());
    this.recoveries.set(id, { id, blocks, reason: "concurrent_delete" });
    this.unsentRecoveries.add(id);
    this.changed(); this.requestSync(100);
  };
  private edit(update: Uint8Array, preserveOnFailure = false): Promise<void> {
    this.hydration.edited();
    this.saving++; this.changed();
    const result = this.localSaves.then(async () => {
      const combined = preserveOnFailure && this.failedEditorUpdate ? this.correctedEditorUpdate() : update;
      try {
        await this.session.accept(encodeBinary(combined), true);
        this.requestSync(100);
        if (preserveOnFailure) { this.failedEditorUpdate = null; this.failedEditorText = ""; }
      } catch (error) {
        if (preserveOnFailure) {
          this.failedEditorUpdate = combined;
          this.failedEditorText = documentPlainText(this.editorDocument);
        }
        this.error = String(error);
        throw error;
      }
    }).finally(() => { this.saving--; this.changed(); });
    this.localSaves = result.catch(() => {});
    return result;
  }
  private correctedEditorUpdate(): Uint8Array {
    // An oversized rejected update may still be retained by Undo. A fresh Y.Doc
    // collects deleted content while preserving the clocks needed by later edits.
    const corrected = new Y.Doc();
    try {
      Y.applyUpdate(corrected, Y.encodeStateAsUpdate(this.editorDocument));
      return Y.encodeStateAsUpdate(corrected);
    } finally { corrected.destroy(); }
  }
  private requestSync(delay = 0) {
    if (this.stopped) return;
    this.syncRequested = true;
    if (this.sendTimer !== undefined || this.syncing) return;
    // Fixed window from the first edit; continuous typing cannot postpone delivery.
    this.sendTimer = setTimeout(() => { this.sendTimer = undefined; void this.sync().catch(() => {}); }, delay);
  }
  sync(): Promise<void> {
    if (this.stopped) return Promise.resolve();
    if (this.syncing) { this.syncRequested = true; return this.syncing; }
    clearTimeout(this.sendTimer); this.sendTimer = undefined;
    this.syncRequested = false;
    this.syncing = this.performSync().finally(() => {
      this.syncing = null;
      if (this.syncRequested) this.requestSync();
      this.releaseIfIdle();
    });
    return this.syncing;
  }
  private async performSync() {
    try {
      await this.session.synchronize();
      this.resumeSubscription();
      if (!this.failedEditorUpdate) this.error = "";
      this.changed();
      void this.saveRecoveries().catch((error: unknown) => { this.maintenanceError = error instanceof Error ? error.message : String(error); this.changed(); });
      void this.refreshMaintenance().catch(() => {});
    } catch (error) {
      void this.saveRecoveries().catch(() => {});
      this.error = error instanceof Error ? error.message : String(error); this.changed(); throw error;
    }
  }
  private refreshMaintenance(): Promise<void> {
    if (this.maintenance) return this.maintenance;
    this.maintenance = this.performMaintenance().catch((error: unknown) => {
      this.maintenanceError = error instanceof Error ? error.message : String(error); this.changed(); throw error;
    }).finally(() => { this.maintenance = null; this.releaseIfIdle(); });
    return this.maintenance;
  }
  private async performMaintenance() {
    if (!this.session.generation) return;
    // Recovery writes carry the same account precondition as body writes.
    if (!this.accountBinding && (await api.getSession({})).user.id !== this.userId) throw new Error(uiText("Sign in with the original account to sync these edits.", "この編集を同期するには、元のアカウントでサインインしてください。"));
    await Promise.all([
      (async () => {
        if (Date.now() - this.lastPresence < 5_000) return;
        const response = this.focused
          ? await api.updateDocumentPresence({ signal: this.auxiliaryAbort.signal, headers: this.headers, params: this.params, body: { sessionId: this.presenceSession } }, false)
          : await api.getDocumentPresence({ signal: this.auxiliaryAbort.signal, headers: this.headers, params: this.params });
        this.people = response.items.map((person) => person.name);
        this.lastPresence = Date.now();
      })(),
    ]);
    this.maintenanceError = "";
    this.changed();
  }
  private saveRecoveries(): Promise<void> {
    if (this.recoverySaving) return this.recoverySaving;
    this.recoverySaving = (async () => {
      if (!this.unsentRecoveries.size) return;
      if (!this.accountBinding && (await api.getSession({})).user.id !== this.userId) throw new Error("document_account_changed");
      for (const id of [...this.unsentRecoveries]) {
        const recovery = this.recoveries.get(id)!;
        await api.saveDocumentRecovery({ headers: this.headers, params: this.params, body: { ...recovery, blocks: recovery.blocks.map((block) => ({ ...block, type: block.type as RecoveryBlock["type"] })) } }, false);
        this.unsentRecoveries.delete(id);
        if (!this.displayedRecoveryIDs.has(id)) this.recoveries.delete(id);
        this.changed();
      }
    })().finally(() => { this.recoverySaving = null; this.releaseIfIdle(); });
    return this.recoverySaving;
  }
  async flush() {
    await this.localSaves;
    if (this.failedEditorUpdate) throw new Error(this.error);
    await this.session.flush();
    this.resumeSubscription();
    // Explicit exit/summary waits for unpublished recovery records, never for presence/history.
    while (this.unsentRecoveries.size) await this.saveRecoveries();
    this.releaseIfIdle();
  }
  async restore(recovery: DocumentRecovery) {
    await this.localSaves;
    if (this.failedEditorUpdate) throw new Error(this.error);
    const preview = new DocumentCore(encodeBinary(Y.encodeStateAsUpdate(this.editorDocument)));
    try { await this.edit(decodeBinary(preview.restore(recovery.blocks, uuidV7))); }
    finally { preview.destroy(); }
  }
  retainView(): () => void {
    this.views++;
    if (this.views === 1) {
      try { this.subscribe(); this.requestSync(); }
      catch (error) { this.views--; this.releaseIfIdle(); throw error; }
    }
    let retained = true;
    return () => {
      if (!retained) return;
      retained = false;
      this.views--;
      if (!this.views) { this.unsubscribe?.(); this.unsubscribe = undefined; }
      this.releaseIfIdle();
    };
  }
  releaseIfIdle() {
    if (this.stopped || this.views || this.listeners.size || this.hasUnsent() || this.syncing) return;
    this.stop();
    for (const [key, value] of sessions) if (value === this) sessions.delete(key);
  }
  stop() {
    this.stopped = true; this.auxiliaryAbort.abort(); clearTimeout(this.timer); clearTimeout(this.sendTimer); this.unsubscribe?.(); this.unsubscribe = undefined;
    window.removeEventListener("beforeunload", this.beforeUnload);
    void this.session.close(); this.editorDocument.destroy(); this.retainedDocument.destroy();
  }
}

async function openDocument(workspaceId: string, meetingId: string): Promise<{ controller: BrowserDocument; release: () => void }> {
  const identity = await api.getSession({});
  const capabilities = await api.getCapabilities({});
  if (capabilities.documents?.version !== 3) throw new Error(uiText("This server does not support this Notes version.", "このサーバーはこのバージョンのノートに対応していません。"));
  const key = `${identity.user.id}/${workspaceId}/${meetingId}`;
  let controller = sessions.get(key);
  if (!controller) {
    const { document } = await api.getMeetingNotes({ headers: { "X-Dahlia-Document-User": identity.user.id }, params: { path: { workspaceId, meetingId } } });
    controller = sessions.get(key) ?? new BrowserDocument(identity.user.id, workspaceId, meetingId, document, capabilities.documents.accountBinding === true);
    sessions.set(key, controller);
  }
  // Own the result before resolving: another view may still be waiting to mount.
  return { controller, release: controller.retainView() };
}

/** Sign-out is blocked while volatile edits need copying or successful delivery. */
export async function finishBrowserDocuments() {
  for (const controller of sessions.values()) if (controller.hasUnsent()) await controller.flush();
  for (const controller of sessions.values()) controller.stop();
  sessions.clear();
}

export async function flushMeetingDocument(workspaceId: string, meetingId: string) {
  if (!sessions.size) return;
  const identity = await api.getSession({});
  const controller = sessions.get(`${identity.user.id}/${workspaceId}/${meetingId}`);
  if (controller) await controller.flush();
}

/** `statusSlot` hosts the sync status outside the editor, e.g. in the page header. */
export function MeetingNotes({ workspaceId, meetingId, editable, statusSlot }: { workspaceId: string; meetingId: string; editable: boolean; statusSlot?: HTMLElement | null }) {
  const [controller, setController] = useState<BrowserDocument>();
  const [error, setError] = useState("");
  useEffect(() => {
    let current = true;
    let release: (() => void) | undefined;
    setController(undefined); setError("");
    void openDocument(workspaceId, meetingId).then((view) => {
      if (current) { release = view.release; setController(view.controller); }
      else view.release();
    }).catch((error: unknown) => { if (current) setError(String(error)); });
    return () => { current = false; release?.(); };
  }, [workspaceId, meetingId]);
  if (error) {
    const alert = <NotesStatus error={error} />;
    return statusSlot ? createPortal(alert, statusSlot) : alert;
  }
  if (!controller) return <p role="status">{uiText("Loading notes…", "ノートを読み込み中…")}</p>;
  return <DocumentEditor key={`${workspaceId}/${meetingId}`} controller={controller} editable={editable} statusSlot={statusSlot} />;
}

function DocumentEditor({ controller, editable, statusSlot }: { controller: BrowserDocument; editable: boolean; statusSlot?: HTMLElement | null }) {
  const [, render] = useState(0);
  const [limitError, setLimitError] = useState("");
  const editor = useEditor({ ...documentEditorOptions(controller.editorDocument, editable, uiText("Add notes…", "メモを入力…"), () => setLimitError(uiText("This edit exceeds the Notes limit. Reduce the content or synchronize before retrying.", "ノートの上限を超えるため変更できません。内容を減らすか、同期後に再試行してください。")), controller.preserveEditorRecovery),
    onUpdate: () => setLimitError(""),
    onFocus: () => { controller.focused = editable; }, onBlur: () => { controller.focused = false; },
  }, [controller]);
  useEffect(() => { editor?.setEditable(editable); }, [editor, editable]);
  useEffect(() => {
    const changed = () => render((count) => count + 1);
    controller.listeners.add(changed);
    const edited = (update: Uint8Array, origin: unknown) => {
      if (origin === "remote" || !editor?.isInitialized || !editor.isEditable) return;
      void controller.editFromEditor(update).catch(() => {});
    };
    controller.editorDocument.on("update", edited);
    return () => { controller.listeners.delete(changed); controller.editorDocument.off("update", edited); controller.focused = false; queueMicrotask(() => controller.releaseIfIdle()); };
  }, [controller, editor]);
  let syncStatus: string;
  if (!controller.hasUnsent()) {
    syncStatus = uiText("Synced", "同期済み");
  } else if (controller.error) {
    syncStatus = uiText("Not synced", "未同期");
  } else {
    syncStatus = uiText("Syncing…", "同期中…");
  }
  const status = <>
    {controller.people.length > 0 && <span className="max-w-48 truncate max-lg:hidden">{uiText("Editing: ", "編集中: ")}{controller.people.join(", ")}</span>}
    <NotesStatus status={syncStatus}
      error={limitError || controller.error} retry={controller.error ? () => { void controller.sync().catch(() => {}); } : undefined} />
  </>;
  return <div className="space-y-3">
    {statusSlot ? createPortal(status, statusSlot) : <div className="flex items-center gap-3 text-xs" role="status">{status}</div>}
    {/* Clicking anywhere in the tall area below the text places the caret. `!` overrides the unlayered editor.css. */}
    <EditorContent editor={editor} className="[&_.tiptap]:min-h-[50vh]!" />
    <details onToggle={(event) => { void controller.toggleRecoveries(event.currentTarget.open).catch(() => {}); }}><summary>{uiText("Preserved deleted paragraphs", "削除された段落の復元用コピー")}</summary>
      <div className="flex gap-3"><button disabled={!controller.recoveryPrevious} className="underline hover:no-underline disabled:opacity-50" onClick={() => { void controller.previousRecoveryPage().catch(() => {}); }}>{uiText("Previous", "前へ")}</button><button disabled={!controller.recoveryNext} className="underline hover:no-underline disabled:opacity-50" onClick={() => { void controller.nextRecoveryPage().catch(() => {}); }}>{uiText("Next", "次へ")}</button></div>
      {[...controller.recoveries.values()].map((recovery) => <div key={recovery.id} className="my-3 border-t pt-3"><pre className="whitespace-pre-wrap">{recovery.blocks.map((block) => block.text).join("\n").slice(0, 2000)}</pre>
        <RecoveryText recovery={recovery} />
        {editable && <button className="underline hover:no-underline" onClick={() => { void controller.restore(recovery).catch(() => {}); }}>{uiText("Insert as new paragraphs", "新しい段落として挿入")}</button>}
      </div>)}
    </details>
  </div>;
}

function RecoveryText({ recovery }: { recovery: DocumentRecovery }) {
  const [open, setOpen] = useState(false);
  return <details onToggle={(event) => setOpen(event.currentTarget.open)}><summary>{uiText("Show full text", "全文を表示")}</summary>
    {open && <pre className="whitespace-pre-wrap">{recovery.blocks.map((block) => block.text).join("\n")}</pre>}</details>;
}

export function NotesStatus({ status, error, retry }: { status?: string; error?: string; retry?: () => void }) {
  if (!error) return <span>{status}</span>;
  return <><span role="alert" className="sr-only">{error}</span><Popover><PopoverTrigger asChild>
    <Button variant="ghost" size="sm" className="h-7 gap-1 text-destructive" aria-label={uiText("Notes status", "ノートの状態")}>
      <AlertTriangle className="size-3.5 shrink-0" /><span>{status ?? uiText("Notes warning", "ノートの警告")}</span>
    </Button>
  </PopoverTrigger><PopoverContent align="end" className="max-w-[calc(100vw-24px)] text-sm">
    <p className="break-words">{error}</p>
    {retry && <Button variant="outline" size="sm" className="mt-3" onClick={retry}>{uiText("Retry", "再試行")}</Button>}
  </PopoverContent></Popover></>;
}

export function PendingDocumentNotice({ userId }: { userId: string }) {
  const [, render] = useState(0);
  useEffect(() => { const timer = setInterval(() => render((n) => n + 1), 1000); return () => clearInterval(timer); }, []);
  const pending = [...sessions.values()].filter((item) => item.userId === userId && item.hasUnsent());
  const warning = uiText("Notes have unsynced changes. Keep this tab open.", "ノートに未送信の編集があります。このタブを開いたままにしてください。");
  return <><span role="status" aria-atomic="true" className="sr-only">{pending.length ? warning : ""}</span>
    {pending.length > 0 && <Popover><PopoverTrigger asChild>
    <Button variant="ghost" size="sm" className="h-7 gap-1 text-destructive" aria-label={uiText("Unsynced notes", "未送信のノート")}>
      <AlertTriangle className="size-3.5" /><span className="max-sm:sr-only">{uiText("Unsynced notes", "未送信のノート")}</span>
    </Button>
  </PopoverTrigger><PopoverContent align="end" className="max-h-[60vh] max-w-[calc(100vw-24px)] overflow-auto text-sm">
    <p>{warning}</p>
    {pending.map((item) => <details key={item.meetingId} className="mt-3"><summary className="cursor-pointer hover:underline">{uiText("Copy unsynced notes", "未送信のノートをコピー")}</summary><pre className="whitespace-pre-wrap break-words">{item.copyText()}</pre></details>)}
  </PopoverContent></Popover>}</>;
}

import { useEffect, useState } from "react";
import { EditorContent, useEditor } from "@tiptap/react";
import * as Y from "yjs";
import { apiOperations as api, apiUrls } from "./generated-operations";
import { RequestError, uiText } from "./api";
import { encodeId } from "../typeid";
import { uuidV7 } from "../id";
import { DocumentSession, type PendingDocumentUpdate } from "../documents/session";
import { DocumentCore, decodeBinary, documentPlainText, encodeBinary, type DocumentRecovery } from "../documents/core";
import { DocumentEditorHydration, documentEditorOptions } from "../documents/editor";
import type { components } from "./generated-api";

type RecoveryBlock = components["schemas"]["DocumentRecovery"]["blocks"][number];
type SharedDocument = NonNullable<components["schemas"]["DocumentEnvelope"]["document"]>;
const sessions = new Map<string, BrowserDocument>();

export class BrowserDocument {
  readonly session: DocumentSession;
  private readonly hydration: DocumentEditorHydration;
  readonly editorDocument = new Y.Doc();
  readonly pending: PendingDocumentUpdate[] = [];
  readonly recoveries = new Map<string, DocumentRecovery>();
  readonly listeners = new Set<() => void>();
  readonly presenceSession = uuidV7();
  people: string[] = [];
  error = "";
  private sequence = 0;
  private events: EventSource | null = null;
  private saving = 0;
  private localSaves: Promise<void> = Promise.resolve();
  private failedEditorUpdate: Uint8Array | null = null;
  private failedEditorText = "";
  private syncing: Promise<void> | null = null;
  private views = 0;
  private stopped = false;
  private timer: ReturnType<typeof setInterval>;
  private readonly unsentRecoveries = new Set<string>();
  private lastPresence = 0;
  focused = false;
  readonly params: { path: { workspaceId: string; documentId: string } };

  constructor(readonly userId: string, workspaceId: string, readonly meetingId: string, initial: SharedDocument | null) {
    this.params = { path: { workspaceId, documentId: initial?.id ?? encodeId("document", uuidV7()) } };
    if (initial) Y.applyUpdate(this.editorDocument, decodeBinary(initial.checkpoint), "remote");
    this.hydration = new DocumentEditorHydration(this.editorDocument);
    this.session = new DocumentSession({
      newID: () => encodeId("documentRecovery", uuidV7()),
      append: (update, local, recovery) => {
        const sequence = ++this.sequence;
        if (local) this.pending.push({ sequence, update });
        if (recovery) { this.recoveries.set(recovery.id, recovery); this.unsentRecoveries.add(recovery.id); }
        this.changed(); return Promise.resolve(sequence);
      },
      pending: () => Promise.resolve([...this.pending]),
      acknowledge: (through) => {
        const firstUnacknowledged = this.pending.findIndex((item) => item.sequence > through);
        this.pending.splice(0, firstUnacknowledged < 0 ? this.pending.length : firstUnacknowledged);
        this.changed(); return Promise.resolve();
      },
      checkpoint: ({ checkpoint }) => {
        this.hydration.receive(decodeBinary(checkpoint));
        this.changed(); return Promise.resolve();
      },
      exchange: async (request) => {
        // A retained tab must never submit one account's unsent content after account switching.
        if ((await api.getSession({})).user.id !== this.userId) throw new Error(uiText("Sign in with the original account to sync these edits.", "この編集を同期するには、元のアカウントでサインインしてください。"));
        let generation = request.generation;
        if (!generation) {
          const response = request.update
            ? await api.initializeMeetingNotes({ params: { path: { workspaceId, meetingId } }, body: { id: this.params.path.documentId } }, false)
            : await api.getMeetingNotes({ params: { path: { workspaceId, meetingId } } });
          if (!response.document) return { generation: null, revision: 0, update: "AAA=" };
          this.bindDocument(response.document.id);
          generation = response.document.generation;
        }
        try {
          return await api.exchangeDocument({ params: this.params, body: { ...request, generation } }, false);
        } catch (error) {
          if (!(error instanceof RequestError) || error.status !== 409 || error.message !== "document_generation_changed") throw error;
          const { document } = await api.getDocument({ params: this.params });
          if (!document) throw error;
          return { generation: document.generation, revision: document.revision, update: document.checkpoint, refreshed: true };
        }
      },
    }, { checkpoint: initial?.checkpoint, generation: initial?.generation ?? null, revision: initial?.revision ?? 0 });
    this.timer = setInterval(() => { void this.sync().catch(() => {}); }, 2_000);
    window.addEventListener("beforeunload", this.beforeUnload);
    if (initial) this.bindDocument(initial.id);
  }
  private bindDocument(id: string) {
    if (this.events && this.params.path.documentId === id) return;
    this.events?.close();
    this.params.path.documentId = id;
    this.events = new EventSource(apiUrls.getDocumentEvents({ params: this.params }));
    this.events.addEventListener("invalidation", () => { void this.sync().catch(() => {}); });
  }
  private beforeUnload = (event: BeforeUnloadEvent) => {
    if (this.hasUnsent()) { event.preventDefault(); event.returnValue = ""; }
  };
  private changed() { for (const listener of this.listeners) listener(); }
  hasUnsent() { return this.saving > 0 || this.failedEditorUpdate !== null || this.pending.length > 0 || this.unsentRecoveries.size > 0; }
  copyText() { return this.failedEditorUpdate ? this.failedEditorText : this.session.core.projection().text; }
  editFromEditor(update: Uint8Array) { return this.edit(this.hydration.captureLocalUpdate(update), true); }
  private edit(update: Uint8Array, preserveOnFailure = false): Promise<void> {
    this.hydration.edited();
    this.saving++; this.changed();
    const result = this.localSaves.then(async () => {
      const combined = preserveOnFailure && this.failedEditorUpdate ? this.correctedEditorUpdate() : update;
      try {
        await this.session.accept(encodeBinary(combined), true);
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
      return Y.encodeStateAsUpdate(corrected, Y.encodeStateVector(this.session.core.document));
    } finally { corrected.destroy(); }
  }
  sync(): Promise<void> {
    if (this.stopped) return Promise.resolve();
    if (this.syncing) return this.syncing;
    this.syncing = this.performSync().finally(() => { this.syncing = null; this.releaseIfIdle(); });
    return this.syncing;
  }
  private async performSync() {
    try {
      await this.session.synchronize();
      if (this.session.generation) {
        for (const id of [...this.unsentRecoveries]) {
          const recovery = this.recoveries.get(id)!;
          await api.saveDocumentRecovery({ params: this.params, body: { ...recovery, blocks: recovery.blocks.map((block) => ({ ...block, type: block.type as RecoveryBlock["type"] })) } }, false);
          this.unsentRecoveries.delete(id);
        }
        let after: string | undefined;
        do {
          const recovered = await api.listDocumentRecoveries({ params: { ...this.params, query: { after } } });
          for (const entry of recovered.items) this.recoveries.set(entry.id, entry);
          after = recovered.nextCursor ?? undefined;
        } while (after);
        if (Date.now() - this.lastPresence >= 5_000) {
          const response = this.focused
            ? await api.updateDocumentPresence({ params: this.params, body: { sessionId: this.presenceSession } }, false)
            : await api.getDocumentPresence({ params: this.params });
          this.people = response.items.map((person) => person.name);
          this.lastPresence = Date.now();
        }
      }
      if (!this.failedEditorUpdate) this.error = "";
      this.changed();
    } catch (error) { this.error = error instanceof Error ? error.message : String(error); this.changed(); throw error; }
  }
  async flush() {
    await this.localSaves;
    if (this.failedEditorUpdate) throw new Error(this.error);
    await this.session.flush(); await this.sync();
  }
  async restore(recovery: DocumentRecovery) {
    await this.localSaves;
    if (this.failedEditorUpdate) throw new Error(this.error);
    const preview = new DocumentCore(this.session.core.checkpoint());
    try { await this.edit(decodeBinary(preview.restore(recovery.blocks, uuidV7))); }
    finally { preview.destroy(); }
  }
  retainView(): () => void {
    this.views++;
    let retained = true;
    return () => {
      if (!retained) return;
      retained = false;
      this.views--;
      this.releaseIfIdle();
    };
  }
  releaseIfIdle() {
    if (this.stopped || this.views || this.listeners.size || this.hasUnsent() || this.syncing) return;
    this.stop();
    for (const [key, value] of sessions) if (value === this) sessions.delete(key);
  }
  stop() {
    this.stopped = true; clearInterval(this.timer); this.events?.close();
    window.removeEventListener("beforeunload", this.beforeUnload);
    void this.session.close(); this.editorDocument.destroy();
  }
}

async function openDocument(workspaceId: string, meetingId: string): Promise<{ controller: BrowserDocument; release: () => void }> {
  const identity = await api.getSession({});
  const capabilities = await api.getCapabilities({});
  if (capabilities.documents?.version !== 1) throw new Error(uiText("This server does not support collaborative Notes.", "この Server は共同編集 Notes に対応していません。"));
  const key = `${identity.user.id}/${workspaceId}/${meetingId}`;
  let controller = sessions.get(key);
  if (!controller) {
    const { document } = await api.getMeetingNotes({ params: { path: { workspaceId, meetingId } } });
    controller = sessions.get(key) ?? new BrowserDocument(identity.user.id, workspaceId, meetingId, document);
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

export function MeetingNotes({ workspaceId, meetingId, editable }: { workspaceId: string; meetingId: string; editable: boolean }) {
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
  if (error) return <p role="alert">{error}</p>;
  if (!controller) return <p role="status">{uiText("Loading notes…", "Notes を読み込み中…")}</p>;
  return <DocumentEditor key={`${workspaceId}/${meetingId}`} controller={controller} editable={editable} />;
}

function DocumentEditor({ controller, editable }: { controller: BrowserDocument; editable: boolean }) {
  const [, render] = useState(0);
  const editor = useEditor({ ...documentEditorOptions(controller.editorDocument, editable),
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
  return <div className="space-y-3">
    <div className="flex flex-wrap items-center gap-3 text-sm" role="status">
      <span>{controller.hasUnsent() ? uiText("Unsynced edits — keep this tab open", "未送信の編集があります。このタブを開いたままにしてください") : uiText("Synced", "同期済み")}</span>
      {controller.people.length > 0 && <span>{uiText("Editing: ", "編集中: ")}{controller.people.join(", ")}</span>}
    </div>
    {controller.error && <p role="alert" className="text-destructive">{controller.error}<button className="ml-3 underline hover:no-underline" onClick={() => { void controller.sync().catch(() => {}); }}>{uiText("Retry", "再試行")}</button></p>}
    {editable && <div className="flex gap-3">
      <button onClick={() => editor?.chain().focus().toggleBold().run()} className="rounded px-2 hover:bg-muted">{uiText("Bold", "太字")}</button>
      <button onClick={() => editor?.chain().focus().toggleHeading({ level: 2 }).run()} className="rounded px-2 hover:bg-muted">{uiText("Heading", "見出し")}</button>
      <button onClick={() => editor?.chain().focus().toggleBulletList().run()} className="rounded px-2 hover:bg-muted">{uiText("List", "箇条書き")}</button>
      <button onClick={() => editor?.commands.undo()} className="rounded px-2 hover:bg-muted">{uiText("Undo", "元に戻す")}</button>
      <button onClick={() => editor?.commands.redo()} className="rounded px-2 hover:bg-muted">{uiText("Redo", "やり直す")}</button>
    </div>}
    <EditorContent editor={editor} className="min-h-48 whitespace-pre-wrap [&_.tiptap]:min-h-48 [&_.tiptap]:outline-none [&_ul]:list-disc [&_ol]:list-decimal [&_ul]:pl-6 [&_ol]:pl-6 [&_h2]:text-xl" />
    {controller.recoveries.size > 0 && <details><summary>{uiText("Preserved deleted paragraphs", "削除された段落の復元用コピー")}</summary>
      {[...controller.recoveries.values()].map((recovery) => <div key={recovery.id} className="my-3 border-t pt-3"><pre className="whitespace-pre-wrap">{recovery.blocks.map((block) => block.text).join("\n")}</pre>
        {editable && <button className="underline hover:no-underline" onClick={() => { void controller.restore(recovery).catch(() => {}); }}>{uiText("Insert as new paragraphs", "新しい段落として挿入")}</button>}
      </div>)}
    </details>}
  </div>;
}

export function PendingDocumentNotice({ userId }: { userId: string }) {
  const [, render] = useState(0);
  useEffect(() => { const timer = setInterval(() => render((n) => n + 1), 1000); return () => clearInterval(timer); }, []);
  const pending = [...sessions.values()].filter((item) => item.userId === userId && item.hasUnsent());
  if (!pending.length) return null;
  return <aside role="status" className="border-b bg-muted p-3 text-sm">{uiText("Notes have unsynced changes. Keep this tab open.", "Notes に未送信の編集があります。このタブを開いたままにしてください。")}
    {pending.map((item) => <details key={item.meetingId}><summary>{uiText("Copy unsynced notes", "未送信の Notes をコピー")}</summary><pre className="whitespace-pre-wrap">{item.copyText()}</pre></details>)}
  </aside>;
}

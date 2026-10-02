import { DocumentSession, type DocumentHost } from "./session";
import type { PendingDocumentUpdate } from "./transport";

// The Worker owns the canonical/staging replicas and outbox. HTTP stays with the tab's account owner.
let session: DocumentSession;
let callID = 0;
const pending: PendingDocumentUpdate[] = [];
const calls = new Map<number, { resolve(value: unknown): void; reject(error: Error): void }>();
const hostCall = (method: string, args: unknown[]): Promise<unknown> => new Promise((resolve, reject) => {
  const id = ++callID; calls.set(id, { resolve, reject }); postMessage({ host: method, id, args });
});
onmessage = (event: MessageEvent<{ id: number; method?: string; args?: unknown[]; result?: unknown; error?: string }>) => {
  const message = event.data;
  if (!message.method) {
    const call = calls.get(message.id); calls.delete(message.id);
    if (message.error) call?.reject(new Error(message.error)); else call?.resolve(message.result);
    return;
  }
  void (async () => {
    const args = message.args ?? [];
    if (message.method === "initialize") {
      pending.push(...(args[1] as PendingDocumentUpdate[] ?? []));
      session = new DocumentSession({
        newID: () => crypto.randomUUID(),
        append: async (update, local, recovery) => {
          const next = await hostCall("append", [update, local, recovery]) as number; if (local) pending.push({ sequence: next, update }); return next;
        },
        pending: () => Promise.resolve([...pending]),
        acknowledge: async (through) => {
          await hostCall("acknowledge", [through]);
          const first = pending.findIndex((entry) => entry.sequence > through);
          pending.splice(0, first < 0 ? pending.length : first);
        },
        exchange: (request) => hostCall("exchange", [request]) as ReturnType<DocumentHost["exchange"]>,
        checkpoint: (state) => hostCall("checkpoint", [state]) as Promise<void>,
      }, args[0] as ConstructorParameters<typeof DocumentSession>[1]);
    } else {
      const methods = { accept: session.accept.bind(session), synchronize: session.synchronize.bind(session),
        flush: session.flush.bind(session), close: session.close.bind(session) };
      const method = methods[message.method as keyof typeof methods];
      if (!method) throw new Error("invalid_document_command");
      await (method as (...args: unknown[]) => Promise<void>)(...args);
    }
    postMessage({ id: message.id, result: null });
  })().catch((error: unknown) => postMessage({ id: message.id, error: error instanceof Error ? error.message : String(error) }));
};

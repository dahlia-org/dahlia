// URL mode elicitation (MCP 2025-11-25) as a wrapper around any MCP transport. It needs nothing from Pi.
export const URL_ELICITATION_REQUIRED = -32042;
const KEEPALIVE_MS = 15_000;

type Message = {
  jsonrpc: "2.0";
  id?: string | number;
  method?: string;
  params?: any;
  result?: unknown;
  error?: { code: number; message: string; data?: any };
};

/** The user's answers: whether to open a page, and whether they finished there so the request can be sent again. */
export interface ElicitationPrompt {
  open(server: string, url: URL, message: string, signal?: AbortSignal): Promise<boolean>;
  finished(server: string, url: URL, signal?: AbortSignal): Promise<boolean>;
}

/** Only web pages: https, or http on this machine. */
export function pageURL(value: unknown): URL | undefined {
  try {
    const url = new URL(String(value));
    const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
    return url.protocol === "https:" || (url.protocol === "http:" && loopback) ? url : undefined;
  } catch {
    return undefined;
  }
}

/** Wraps an MCP transport: declares URL mode elicitation and answers it, so Pi's MCP client never sees it. */
export function withElicitation(inner: any, server: string, prompt: ElicitationPrompt, openURL: (url: string) => void) {
  const listeners = new Set<(message: Message) => void>();
  type Request = { message: Message; options?: any; controller: AbortController; signal: AbortSignal; onAbort: () => void };
  const inFlight = new Map<string | number, Request>();
  // The server's request IDs are separate from the client's IDs in inFlight.
  const elicitations = new Map<string | number, AbortController>();
  const lifetime = new AbortController();
  let waiting = 0;
  let tick = 0;
  let timer: ReturnType<typeof setInterval> | undefined;
  const emit = (message: Message) => {
    if (lifetime.signal.aborted) return;
    for (const listener of listeners) listener(message);
  };
  const forget = (id: string | number) => {
    const request = inFlight.get(id);
    request?.signal.removeEventListener("abort", request.onAbort);
    inFlight.delete(id);
  };
  const dispose = () => {
    lifetime.abort();
    clearInterval(timer);
    for (const id of inFlight.keys()) forget(id);
    elicitations.clear();
  };
  inner.onClose(dispose);

  const ask = async (work: () => Promise<boolean>, signal: AbortSignal) => {
    if (signal.aborted) return false;
    let aborted: () => void = () => {};
    const cancelled = new Promise<boolean>((resolve) => { aborted = () => resolve(false); });
    signal.addEventListener("abort", aborted, { once: true });
    try {
      return await Promise.race([work(), cancelled]) && !signal.aborted;
    } catch {
      return false;
    } finally {
      signal.removeEventListener("abort", aborted);
    }
  };

  // The client gives up on a request without progress (60 s by default); progress keeps a waiting call alive.
  // shortcut: requests without a progress token (only tool calls have one) can still time out; give them one if needed.
  const keepAlive = async <T>(work: () => Promise<T>) => {
    if (waiting++ === 0) {
      timer = setInterval(() => {
        for (const { message } of inFlight.values()) {
          const progressToken = message.params?._meta?.progressToken;
          if (progressToken === undefined) continue;
          emit({ jsonrpc: "2.0", method: "notifications/progress", params: { progressToken, progress: ++tick, message: "Waiting for you in the browser" } });
        }
      }, KEEPALIVE_MS);
    }
    try {
      return await work();
    } finally {
      if (--waiting === 0) clearInterval(timer);
    }
  };

  const consent = async (url: URL, message: string, signal: AbortSignal) => {
    if (!(await ask(() => prompt.open(server, url, message, signal), signal)) || signal.aborted) return false;
    try {
      openURL(url.href);
      return true;
    } catch {
      return false;
    }
  };

  const answer = async (request: Message) => {
    const id = request.id!;
    const controller = new AbortController();
    elicitations.get(id)?.abort();
    elicitations.set(id, controller);
    const signal = AbortSignal.any([lifetime.signal, controller.signal]);
    try {
      const { mode, url: raw, message = "" } = request.params ?? {};
      const url = pageURL(raw);
      const reply = mode !== "url"
        ? { error: { code: -32602, message: "This client supports only URL mode elicitation." } }
        : !url
          ? { error: { code: -32602, message: "The elicitation URL must use https." } }
          : { result: { action: (await keepAlive(() => consent(url, String(message), signal))) ? "accept" : "decline" } };
      if (signal.aborted) return;
      await inner.send({ jsonrpc: "2.0", id, ...reply }).catch(() => {});
    } finally {
      if (elicitations.get(id) === controller) elicitations.delete(id);
    }
  };

  const retry = async (response: Message, request: Request) => {
    const elicitations = response.error?.data?.elicitations;
    const pages: [URL | undefined, string][] = (Array.isArray(elicitations) ? elicitations : [])
      .filter((elicitation: any) => elicitation?.mode === "url")
      .map((elicitation: any) => [pageURL(elicitation.url), String(elicitation.message ?? "")]);
    const proceed = pages.length > 0 && pages.every(([url]) => url) && await keepAlive(async () => {
      for (const [url, message] of pages) if (!(await consent(url!, message, request.signal))) return false;
      return ask(() => prompt.finished(server, pages[0][0]!, request.signal), request.signal);
    });
    if (request.signal.aborted || inFlight.get(response.id!) !== request) return;
    if (proceed) {
      try {
        return await inner.send(request.message, request.options);
      } catch {
        // The original error explains the failure better than the transport's.
      }
    }
    forget(response.id!);
    emit(response);
  };

  inner.onMessage((message: Message) => {
    if (lifetime.signal.aborted) return;
    if (message.method === "notifications/cancelled") {
      const pending = elicitations.get(message.params?.requestId);
      if (pending) {
        pending.abort();
        elicitations.delete(message.params.requestId);
        return;
      }
    }
    if (message.method === "elicitation/create" && message.id !== undefined) return void answer(message);
    // Retries follow the user's answer, so the server's notice that a page finished is not needed.
    if (message.method === "notifications/elicitation/complete") return;
    if (message.method === undefined && message.id !== undefined) {
      const request = inFlight.get(message.id);
      if (request && message.error?.code === URL_ELICITATION_REQUIRED) return void retry(message, request);
      forget(message.id);
    }
    emit(message);
  });

  return {
    start: () => inner.start(),
    send(message: Message, options?: any) {
      if (lifetime.signal.aborted) return Promise.reject(new Error("MCP transport is closed."));
      if (message.method === "initialize") {
        const capabilities = { ...message.params?.capabilities, elicitation: { url: {} } };
        message = { ...message, params: { ...message.params, capabilities } };
      } else if (message.method === "notifications/cancelled") {
        inFlight.get(message.params?.requestId)?.controller.abort();
        forget(message.params?.requestId);
      } else if (message.method !== undefined && message.id !== undefined) {
        const controller = new AbortController();
        const signal = AbortSignal.any([lifetime.signal, controller.signal, ...(options?.signal ? [options.signal] : [])]);
        const id = message.id;
        const request = { message, options, controller, signal, onAbort: () => forget(id) };
        inFlight.set(id, request);
        signal.addEventListener("abort", request.onAbort, { once: true });
        if (signal.aborted) forget(id);
      }
      return inner.send(message, options).catch((error: Error) => {
        if (message.id !== undefined) forget(message.id);
        throw error;
      });
    },
    close: () => { dispose(); return inner.close(); },
    onMessage(listener: (message: Message) => void) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    onError: (listener: (error: Error) => void) => inner.onError(listener),
    onClose: (listener: () => void) => inner.onClose(listener),
    setProtocolVersion: (version: string) => inner.setProtocolVersion?.(version),
  };
}

// Transcript surface for the macOS app. Swift owns the transcript window and sends a diff of it; this page only renders.
// Rendering runs in the WebContent process, so a slow layout never stops the app's main thread.

export type TranscriptRow = {
  id: string;
  time: string;
  text: string;
  translation?: string;
  speaker?: string;
  speakerColor?: string;
  confirmed: boolean;
};

type Viewport = { following: boolean; anchorID?: string; offset: number };

export type TranscriptUpdate = {
  seq: number;
  reset?: boolean;
  /** Every row ID in display order. Rows missing here are removed. */
  order: string[];
  /** Only new or changed rows. */
  rows: TranscriptRow[];
  hasEarlier: boolean;
  hasLater: boolean;
  scrollTo?: "top" | "bottom";
  restoreViewport?: Viewport;
  baseSize: number;
};

type Message =
  | { type: "ready" }
  | { type: "presented"; seq: number }
  | { type: "requestPage"; direction: "earlier" | "later" }
  | ({ type: "viewport"; seq: number } & Viewport);

/** The DOM operations `reconcile` needs, so the ordering logic is testable without a browser. */
export type RowContainer<Node> = {
  firstChild: Node | null;
  nextSibling(node: Node): Node | null;
  insertBefore(node: Node, before: Node | null): void;
  remove(node: Node): void;
};

/** Puts the container's children in `order`, moving only nodes that are out of place. */
export function reconcile<Node>(container: RowContainer<Node>, nodes: Map<string, Node>, order: string[]): void {
  const keep = new Set(order);
  for (const [id, node] of nodes) {
    if (!keep.has(id)) {
      container.remove(node);
      nodes.delete(id);
    }
  }
  let cursor = container.firstChild;
  for (const id of order) {
    const node = nodes.get(id);
    if (node === undefined) continue;
    if (node === cursor) {
      cursor = container.nextSibling(node);
    } else {
      container.insertBefore(node, cursor);
    }
  }
}

/** Which page to ask for after a scroll, given the distance in pixels from each end. */
export function pageToRequest(fromTop: number, fromBottom: number, hasEarlier: boolean, hasLater: boolean): "earlier" | "later" | null {
  const prefetch = 1200;
  if (hasEarlier && fromTop < prefetch) return "earlier";
  if (hasLater && fromBottom < prefetch) return "later";
  return null;
}

function post(message: Message): void {
  (window as unknown as { webkit?: { messageHandlers?: { transcript?: { postMessage(value: Message): void } } } })
    .webkit?.messageHandlers?.transcript?.postMessage(message);
}

function renderRow(element: HTMLElement, row: TranscriptRow): void {
  element.className = row.confirmed ? "row" : "row preview";
  const time = document.createElement("span");
  time.className = "time";
  time.textContent = row.time;
  const body = document.createElement("div");
  body.className = "body";
  const text = document.createElement("p");
  text.className = "text";
  if (row.speaker) {
    const speaker = document.createElement("span");
    speaker.className = "speaker";
    speaker.textContent = row.speaker;
    if (row.speakerColor) speaker.style.background = row.speakerColor;
    text.append(speaker);
  }
  text.append(row.text);
  body.append(text);
  if (row.translation) {
    const translation = document.createElement("p");
    translation.className = "translation";
    translation.textContent = row.translation;
    body.append(translation);
  }
  element.replaceChildren(time, body);
}

export function install(root: HTMLElement): void {
  const nodes = new Map<string, HTMLElement>();
  const scroller = document.scrollingElement ?? document.documentElement;
  const container: RowContainer<HTMLElement> = {
    get firstChild() { return root.firstElementChild as HTMLElement | null; },
    nextSibling: (node) => node.nextElementSibling as HTMLElement | null,
    insertBefore: (node, before) => { root.insertBefore(node, before); },
    remove: (node) => { node.remove(); },
  };
  let hasEarlier = false;
  let hasLater = false;
  let requested: "earlier" | "later" | null = null;
  let following = true;
  let sequence = 0;
  let scrollScheduled = false;
  let reportedScrollTop = 0;

  const distanceFromBottom = () => scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;

  const visibleAnchor = (keep?: Set<string>) => {
    for (const child of root.children) {
      const element = child as HTMLElement;
      const bounds = element.getBoundingClientRect();
      if (bounds.bottom > 0 && bounds.top < window.innerHeight && (!keep || keep.has(element.dataset.rowId ?? ""))) {
        return { element, top: bounds.top };
      }
    }
    return undefined;
  };

  const reportViewport = () => {
    following = !hasLater && distanceFromBottom() < 24;
    const anchor = visibleAnchor();
    post({ type: "viewport", seq: sequence, following, anchorID: anchor?.element.dataset.rowId, offset: anchor?.top ?? 0 });
    reportedScrollTop = scroller.scrollTop;
  };

  const checkScroll = () => {
    scrollScheduled = false;
    reportViewport();
    const page = pageToRequest(scroller.scrollTop, distanceFromBottom(), hasEarlier, hasLater);
    if (page && page !== requested) {
      requested = page;
      post({ type: "requestPage", direction: page });
    }
  };

  window.addEventListener("scroll", () => {
    // Ignore delayed events from applying rows, but retain a real scroll even if content updates before its frame.
    if (scrollScheduled || scroller.scrollTop === reportedScrollTop) return;
    scrollScheduled = true;
    if (document.visibilityState === "visible") requestAnimationFrame(checkScroll);
    else checkScroll();
  }, { passive: true });

  const apply = (update: TranscriptUpdate) => {
    const wasAtBottom = following && distanceFromBottom() < 24;
    // Retain a visible row through prepend and leading-window eviction, including variable row heights.
    const anchor = !update.reset && update.scrollTo === undefined && !wasAtBottom
      ? visibleAnchor(new Set(update.order)) : undefined;
    if (update.reset) {
      root.replaceChildren();
      nodes.clear();
    }
    document.documentElement.style.setProperty("--base", `${update.baseSize}px`);
    sequence = update.seq;
    for (const row of update.rows) {
      let element = nodes.get(row.id);
      if (!element) {
        element = document.createElement("div");
        nodes.set(row.id, element);
      }
      element.dataset.rowId = row.id;
      renderRow(element, row);
    }
    reconcile(container, nodes, update.order);
    hasEarlier = update.hasEarlier;
    hasLater = update.hasLater;
    requested = null;
    if (update.scrollTo === "top") scroller.scrollTop = 0;
    else if (update.scrollTo === "bottom" || update.restoreViewport?.following) scroller.scrollTop = scroller.scrollHeight;
    else if (update.restoreViewport) {
      const row = nodes.get(update.restoreViewport.anchorID ?? "");
      if (row) scroller.scrollTop += row.getBoundingClientRect().top - update.restoreViewport.offset;
    }
    else if (wasAtBottom && !hasLater) scroller.scrollTop = scroller.scrollHeight;
    else if (anchor) scroller.scrollTop += anchor.element.getBoundingClientRect().top - anchor.top;
    reportViewport();
    // Report after the frame that shows this update. A hidden page draws no frames, so report right away.
    if (document.visibilityState === "visible") requestAnimationFrame(() => post({ type: "presented", seq: update.seq }));
    else post({ type: "presented", seq: update.seq });
  };

  (window as unknown as { dahliaTranscript: { apply: typeof apply } }).dahliaTranscript = { apply };
  post({ type: "ready" });
}

if (typeof document !== "undefined") {
  const root = document.getElementById("rows");
  if (root) install(root);
}

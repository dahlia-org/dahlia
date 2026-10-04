import { uiText } from "./api";
import { uuidV7 } from "../model/id";
import { z } from "zod";
import { apiUrls } from "./generated-operations";

const documentHint = z.object({ workspaceId: z.string(), meetingId: z.string(), documentId: z.string().nullable(), cursor: z.string(), unavailable: z.boolean() });
type Hint = z.infer<typeof documentHint>;
type Subscription = { workspaceId: string; meetingId: string; listeners: Set<(hint?: Hint) => void> };

/** One owner per browser tab. Changing subscriptions replaces an immutable, authenticated GET. */
export class SyncNotifications {
  private readonly tab = uuidV7().replaceAll("-", "");
  private user: string | undefined;
  private source: EventSource | undefined;
  private readonly notes = new Map<string, Subscription>();
  private readonly domain = new Set<(reconnected: boolean) => void>();
  private timer: ReturnType<typeof setTimeout> | undefined;
  connected = false;

  private bind(user: string) {
    if (this.user === user) return;
    this.closeConnection();
    this.notes.clear(); this.domain.clear(); this.user = user;
  }
  subscribeDomain(user: string, listener: (reconnected: boolean) => void) {
    this.bind(user); this.domain.add(listener); this.replace();
    return () => { if (this.user !== user) return; this.domain.delete(listener); this.replace(); };
  }
  subscribeNotes(user: string, workspaceId: string, meetingId: string, listener: (hint?: Hint) => void) {
    // App's domain subscription owns account changes. A delayed Notes load may
    // initialize an idle owner, but must never displace active account listeners.
    if (this.user !== user && (this.domain.size || this.notes.size)) {
      throw new Error(uiText("The account has changed. Reopen these Notes.", "アカウントが変更されました。ノートを開き直してください。"));
    }
    this.bind(user);
    const key = `${workspaceId}/${meetingId}`;
    let subscription = this.notes.get(key);
    if (!subscription) {
      if (this.notes.size >= 32) throw new Error(uiText("Close a Notes view before opening another.", "別のノートを開くには、開いているノートを閉じてください。"));
      subscription = { workspaceId, meetingId, listeners: new Set() };
      this.notes.set(key, subscription);
    }
    subscription.listeners.add(listener);
    if (subscription.listeners.size === 1) this.replace();
    const retained = subscription;
    return () => {
      if (this.user !== user || this.notes.get(key) !== retained) return;
      retained.listeners.delete(listener);
      if (!retained.listeners.size) { this.notes.delete(key); this.replace(); }
    };
  }
  private closeConnection() {
    this.source?.close();
    this.source = undefined;
    this.connected = false;
  }
  private replace() {
    // Close immediately: queued events from a removed subscription cannot reach a closed view.
    this.closeConnection();
    clearTimeout(this.timer);
    if (!this.domain.size && !this.notes.size) return;
    this.timer = setTimeout(() => this.open(), 0);
  }
  private open() {
    this.timer = undefined;
    const query = { user: this.user!, tab: this.tab,
      notes: JSON.stringify([...this.notes.values()].map(({ workspaceId, meetingId }) => ({ workspaceId, meetingId }))) };
    const source = new EventSource(apiUrls.getEvents({ params: { query } }));
    this.source = source;
    source.addEventListener("open", () => {
      if (this.source !== source) return;
      this.connected = true;
      for (const listener of this.domain) listener(true);
      // Initial/reconnect reads occur after subscribing, covering the replacement gap.
      for (const subscription of this.notes.values()) for (const listener of subscription.listeners) listener();
    });
    source.addEventListener("error", () => { if (this.source === source) this.connected = false; });
    source.addEventListener("invalidation", () => {
      if (this.source === source) for (const listener of this.domain) listener(false);
    });
    source.addEventListener("document", (event) => {
      if (this.source !== source) return;
      let value: unknown;
      if (typeof event.data !== "string") return;
      try { value = JSON.parse(event.data); } catch { return; }
      const parsed = documentHint.safeParse(value);
      if (!parsed.success) return;
      const hint = parsed.data, key = `${hint.workspaceId}/${hint.meetingId}`;
      const subscription = this.notes.get(key);
      if (!subscription) return;
      for (const listener of subscription.listeners) listener(hint);
      if (hint.unavailable) { this.notes.delete(key); this.replace(); }
    });
  }
}
export const syncNotifications = new SyncNotifications();

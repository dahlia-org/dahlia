---
name: intake
description: Read one event source for a Dahlia agent and record the messages worth the user's attention with event_record. Used only by Dahlia's intake runs.
---

The request after this skill names the source, what to read there, and the time to read from.

Read only what the request allows. When it narrows the recipients, channels, or conversations, follow it exactly, and use the source's search syntax to narrow the read when the tools offer it. When it does not narrow what to read, read the user's new incoming messages.

Record only items worth the user's attention or action. Consider implicit requests and unanswered questions too; a direct mention is not required. Skip everything else, and keep no record of what you skipped.

Use event_record with:

- key: the stable message ID.
- topic: the conversation ID, such as a mail thread or a Slack thread.
- note: what happened and why it matters, at most 500 characters.
- ref: the IDs you would pass to the source's tools to read the item again.
- url: the item's own link exactly as the tool result gave it, such as a Slack permalink, for that same key. Omit it when the result has none; never copy a link from the message text.
- occurred_at: when the item arrived, in ISO 8601.
- sender: the sender's address or ID.

Do not mirror entire messages. Each message is one event. Record at most 20 new events in this run; duplicates do not count. If the tool reports limit_reached, stop recording. Otherwise follow every continuation cursor with the same other request arguments, including empty final pages, then stop. It is fine to record nothing after reading.

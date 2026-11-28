# Using the Dahlia macOS app

UI names are given as English / Japanese. Settings opens with Cmd+, or from the menu bar item. Its sidebar groups are
This Mac / このMac (General, Appearance, Permissions, Data Protection), Features / 機能 (Workspace, Meetings, Calendar,
Meeting Links), Agent / エージェント (Providers, Models, Connectors, Skills, Memory, Advanced Settings), and Advanced /
詳細 (Dahlia MCP, Search, Diagnostics). Transcription, screenshots, stop detection, and live subtitles are steps of
the Meetings page, not separate items.

## Screenshots

- Choose what to capture from the recording bar's Screen / 画面 menu: Not Selected / 未設定 (the default, no capture),
  Entire Desktop / デスクトップ全体, or one window. Dahlia's own windows are not listed. Entire Desktop captures the first
  display macOS reports, so pick the window itself when you use several displays.
- Capture runs only while recording. There is no manual "capture now" action.
- Settings (Meetings page, screenshot step):
  - Adaptive Screenshot Interval / 取得間隔をアダプティブにする, on by default.
  - Screenshot Interval / 取得間隔: 5, 10, 20 (default), or 30 seconds.
  - Screenshot Change Threshold / 画面変化の閾値: 5 (default), 10, 20, 30, or 50 percent of the screen.
  - Select Meeting Window Automatically / 会議ウィンドウを自動で選択, off by default. When recording starts from a meeting
    link, Dahlia waits about 30 seconds for the meeting window and falls back to the frontmost window.
  - Detect Changes in Shared Content Only / 共有領域のみで画面差分を判定 and Save Shared Content Only / 共有領域のみを保存,
    both off by default. Use them to ignore the meeting app's own chrome and participant tiles.

### How adaptive capture decides

Dahlia compares a small grayscale fingerprint of the screen several times a second.

- A change is saved once the screen has been still for 1 second, so a slide transition or a scroll is captured right
  away instead of mid-animation. Changes that settle within 3 seconds count as one.
- Areas that keep changing, such as camera video, a moving cursor, or an animation, are treated as live and ignored;
  motion that never settles for 20 seconds counts as live too. A video call alone does not fill the meeting with
  screenshots.
- The interval is the fallback: gradual changes and mostly moving screens are checked once per interval.
- A screen identical to one of the last 100 saved screens is not saved again, so going back to an earlier slide does
  not duplicate it.
- With adaptive off, the whole screen is compared once per interval against the threshold.

Tips: if slides are missed, lower the threshold or the interval, or capture the presentation window instead of the
desktop. If too many near-duplicates are saved, raise the threshold or turn on the shared-content options.

When image analysis is enabled, the Pi runtime analyzes saved screenshots for on-screen text (OCR) and a caption,
which makes them searchable. Summary screenshot selection runs independently of this switch.
See `summary-generation.md` for how screenshots reach a summary.

## Recording

- Start or stop with the Record button or Cmd+Shift+R. With a Meeting selected, recording appends to it; otherwise a
  new Meeting starts. Cmd+N creates a new Meeting.
- Pick the microphone and whether to capture system audio from the recording bar menus.
- Echo cancellation is always on for the built-in microphone. For an external microphone, turn on Use Echo
  Cancellation with External Microphones / 外部マイクでもAECを使用 (off by default).
- Auto-record a calendar event: open the event's menu and turn on Auto-record / 自動録音. It applies once, to timed
  events, and Dahlia must be running.
- Auto-stop: turn on Automatically Stop Recording When the Meeting Ends / ミーティング終了時に録音を自動停止 under stop
  detection (off by default). It watches meeting apps such as Zoom, Teams, Slack, Discord, Webex, FaceTime, and
  browsers (not Safari). It stops when every watched meeting app has released the microphone for 4 seconds, and only
  after both the recording and the meeting have lasted 30 seconds. It does nothing for in-person meetings.
- Recorded audio (CAF) in a local Workspace is kept for 3 days by default. Change it in Data Protection > Local
  Workspace CAF Recording Retention: forever, 1, 3, 7, or 14 days. Retranscription needs the audio, so keep it longer
  if you may retranscribe.

## Transcription

- Apple Speech transcribes on the Mac after recording. Set the language in the transcription step of the Meetings
  page; it defaults to the system language. Automatic language detection can be enabled with the languages to detect.
- Process automatically after recording / 録音終了後に自動処理 (on by default) transcribes and summarizes when recording
  stops. This app-account setting applies to every Desktop Workspace on this Mac. Export summary to workspace is on
  by default.
- Retranscribe / 文字起こしをやり直す is in the Meeting's menu when retained audio exists. It can run with another
  language or auto-detection and keeps the existing summary unless you choose to regenerate it.
- Live subtitles can be shown in an overlay and translated for display with Apple Translation; translation does not
  change the saved transcript.
- Transcripts do not identify speakers on the Desktop.

## Notes

The Notes / ノート tab (Cmd+2) of a Meeting is a document you can write in during or after the Meeting. Its text is
sent to the summary when the summary is generated, so write the goal, background, or correct names there first.
Notes stay on the Mac and are not available through MCP.

Meeting tabs: Cmd+1 Summary, Cmd+2 Notes, Cmd+3 Screenshots, Cmd+4 Transcript.

## Summaries

- Automatic summaries after recording use Summary style / まとめ方 in Agent > Models, which also holds the summary
  model and the image analysis switch. These app-account settings apply to every Desktop Workspace on this Mac.
- Generate Summary / 要約を生成 opens a dialog where you choose the detail level / 詳細度 for that run. Select several
  Meetings to regenerate their summaries together.
- The output language is set per Workspace (Settings > Workspace).
- Custom instructions / カスタム指示 in Agent > Advanced Settings > General apply to chat; turn on 要約生成にも適用する
  to apply them to summaries too.
- Share: Copy for Google Docs, Copy for Slack, or Export to Google Drive (done by Dahlia AI through a Google Drive MCP).
- Versions: in a Workspace without an export folder, the summary tab lists earlier versions and can make one current.
- To correct a summary, ask an AI with Dahlia MCP write access (see the `summary-editor` skill).

## Projects and Workspaces

- Projects / プロジェクト tab (Ctrl+2). A Project has a parent (Workspace root or a root Project), a type (root only),
  and a description that is sent to every summary in it. See the `projects-optimizer` skill for how to structure them.
- A Workspace can have a local export folder (Settings > Workspace, row menu). Summaries are then written there as
  Obsidian-compatible Markdown under the Project's path, and Open in Obsidian appears when Obsidian is installed.

## Search

- Cmd+F searches Meeting titles, tags, calendar titles, descriptions, and summaries. Transcripts are not searched.
- Settings > Search: download IPADIC NEologd for better Japanese tokenization, import a user dictionary CSV for your
  own terms, and adjust ranking weights. Dictionary changes apply only after Rebuild Full-Text Search.

## AI and connections

- Chat / チャット (Ctrl+3) talks to Dahlia AI, which runs on Pi. Sign in under Agent > Providers (ChatGPT, Claude,
  Databricks, Unity Gateway, Dahlia account, Google).
- Dahlia MCP (Advanced): choose the app (Claude Code, Codex CLI, or JSON for others), the Workspaces, and whether to
  allow AI to edit (off by default). Run the shown command, then restart that app. After a Dahlia update, open Dahlia
  once before using MCP again.
- Chat can list and read MCP resources only with an explicit registered `server` argument. An unscoped list is blocked,
  including when Pi has connected other servers from a trusted working folder. Use `list_mcp_resources` with that server,
  then `read_mcp_resource` with the same server and a returned URI.
- Backups: Data Protection > Backups creates and imports backups of local Workspaces.

## What each kind of AI run can use

Help > Chat and agent differences / チャットとエージェントの違い shows this in the app.

A worker (a task the agent hands off) is an ordinary thread with the same core work capabilities as chat.
For writes to other services, chat uses the mode chosen in the chat. The agent's Workers / ワーカー setting limits
how permissive a task can be; a stricter approval mode chosen in the task thread still applies.
While handling handed-off work, a worker's thread tools only read: it cannot create
children or manage other threads. A subagent made by a chat with `delegate_task` has the same thread-tool limits,
and its approval mode is never looser than its parent's.

Agents can also read upcoming calendar events and invitation status.

| | Chat and workers | Agent | Intake | Scheduled run |
| --- | --- | --- | --- | --- |
| Runs when | You send a message, or the agent hands it work | You send a message, or events arrive | Per source, while the app is open | At the scheduled time, while the app is open |
| Commands and files | Working folder, read, write, run commands | Only its home, no commands | None | Read only |
| Dahlia meeting data | Read and write (changes follow the approval mode) | Read only | None | Approved tools, read only |
| Connector MCP tools | Yes (writes follow the approval mode) | None | Its one source, read only | Approved tools, read only |
| MCP resources | Registered servers | None | None | None |
| Web search | When Web Access is installed | None | None | None |
| Skills | Use, create, edit | None | Only the intake procedure | Read only |
| Memory | Read and write (when on) | Read only | None | Read only |
| Thread tools | Chat: launch, delegate, manage. Workers: read only during handed-off work | Launch, delegate, manage (as tasks) | None | None |
| Writes to other services | Follow the approval mode | Never | Never | Never |

Summaries and image analysis use no tools, MCPs, or skills. While recording, automatic agent runs, intake, and
scheduled runs do not start. Chat, user messages to an agent, and manually requested summaries remain available.

## Shortcuts

Cmd+, Settings · Cmd+N new Meeting · Cmd+Shift+R record · Cmd+F search · Cmd+B sidebar · Cmd+[ / Cmd+] back and
forward · Cmd+1–4 Meeting tabs · Ctrl+1–3 Meetings, Projects, Chat.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No system audio or screenshots | Settings > Permissions: Screen & System Audio Recording |
| No microphone audio | Settings > Permissions: Microphone, and the microphone chosen in the recording bar |
| No screenshots at all | The Screen menu is Not Selected by default; choose a window or the desktop |
| Summaries or image analysis stay pending | Pi is not installed or not signed in; check Agent > Providers |
| MCP reports a schema error after an update | Open Dahlia once so it can migrate the database |
| Cannot retranscribe | The audio was removed by the retention period |

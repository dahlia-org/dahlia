# Super Agent（旧称 Dahlia Bot）を1本のスレッドにまとめる改修

対象: macOS の内蔵 Pi。Private Web / Electron は内蔵 Pi がないため対象外。
状態: 実装・自動検証済み。実アプリでの画面の確認と、実モデルでの動作の確認が残る。方針は 2026-11-25 にユーザーが決めた。
前提: [Dahlia Bot（AI 秘書）](2026-11-23-dahlia-bot-secretary.md)の 3A-2・3A-5（PR #840、未リリース）の上に作る。未リリースの `v68_alwaysOnAgent` は書き直した。
現在の契約は[仕様](../spec/desktop/always-on-agent.md)と[スレッドの管理](../spec/desktop/chat-thread-orchestration.md)にある。

## 何を変えたか

| | 前 | 今 |
| --- | --- | --- |
| 振り分け役 | 裏で動く Router と、会話用の秘書のスレッドの2つ | Super Agent のスレッド1本。会話も振り分けもここで行う |
| 仕事をするもの | タスク専用の Worker（専用の権限、フォルダ、配送の仕組み） | Super Agent が `thread_launch` で起動する通常のスレッド |
| タスク | 専用の tool（`task_create` など8つ）と配送の表 | 起動したスレッドに付ける記録（`agent_tasks`）。終えるのは `task_finish` かユーザー |
| 新しいイベント | Router の入力に本文を並べて渡す。続報は話題で自動振り分け | 件数だけ通知し、Super Agent が `inbox_read` で読んで `event_ids` で渡す |
| 入口 | 設定の Always-on タブ | サイドバーの Agents セクションと、スレッドの右パネル（受信箱と設定） |
| 手引き | 設定（UserDefaults） | home の `SOUL.md` |

なくしたもの: Worker のプロファイルとプロンプト、案件ごとのフォルダ、Action と Policy の書き込みの関所、タイマー、話題の自動振り分け、配送と再配送。

## 決まり

- **タスクの作り方**: `thread_launch` の起動元が Super Agent のスレッドなら、アプリがタスクを記録し、結果を自動で Super Agent に返す（承認待ちは返さず、起動のカードで見せる）。モデルはタスクにするかを指定しない（透過的）。通常のチャットの `thread_launch` はタスクにならず、結果も戻らない。
- **タスクの状態**: スレッドの実行状態とは別に持つ。終えるのは Super Agent の `task_finish` か、右パネルの「完了にする」だけ。Super Agent が終わったタスクに `thread_send` すると進行中に戻る。
- **権限**: 起動したスレッドは、無人の間も通常のチャットと同じ権限で動く。Super Agent 自身は bash も外部の MCP も持たない。
- **イベント**: `event_ids` は Super Agent のスレッドからだけ受け付ける。渡したイベントは処理済みになり、本文は fence で包んでメッセージに付く。
- **通知のターン**: `thread_launch`・`thread_send` を使える。`soul_write` だけはユーザー自身のターンに限る。
- **録音中**: 通知のターンと、Super Agent が依頼した run は始めない。
- **履歴に出さない実行**: Super Agent の責務の範囲のもの（通知のターン、取り込み、`delegate_task` の子）だけで、home で動かす。

## 決めたこと

ユーザーが 2026-11-25 に決めた。

1. タスクは、Super Agent が起動したスレッドに付ける記録にする。概念と右パネルの一覧は残す。
2. 起動したスレッドは通常のチャットと同じ権限で動かす（資料作成などに bash が要る）。メールが起点の場合も同じで、そのリスクは受け入れる。
3. 通知のターンからの `thread_launch` を許す。
4. 同じ話題の続報は、モデルが見て振り分ける。
5. 名前は Super Agent、サイドバーの見出しは Agents、home は `bots/super-agent/`。
6. 右パネルは受信箱と設定の切り替え。全体を止めるトグルは置かない。
7. スレッドの tool は T3 Code にそろえる（`thread_*`、`delegate_task`・`task_status`・`task_cancel`）。

## 未確認

- 実アプリでの Agents セクション、右パネル、タスクのカードの表示。
- 実モデルでの Super Agent の振り分けと、起動したスレッドの動作。
- 長く続く1本のスレッドで、Pi の会話の要約がどう働くか。
- 通知のターンを加えたときの1日あたりのトークン量。

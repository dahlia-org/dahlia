# Architecture Decision Records

ADR は、設計判断を行った時点の背景、選択肢、トレードオフを残す履歴である。
現在の構成、横断的な設計原則、実装との適合状況、修正完了条件は
[ARCHITECTURE.md](../../ARCHITECTURE.md) を正本とする。

Codex は全 ADR を順番に読まず、最初にこの一覧から現在の作業に関係する記録だけを選ぶ。
既存の決定を変更または反転する場合は、新しい ADR を追加して置換関係を記録し、過去の本文を現在形へ書き換えない。

| ADR | Area | Decision | Status / relationship |
| --- | --- | --- | --- |
| [0001](0001-summary-document-ast.md) | Summary | `SummaryDocument` AST をサマリーの正準表現にする | Accepted |
| [0002](0002-isolate-recording-critical-path-from-main-actor.md) | Recording / Concurrency | 録音と確定データの保存を MainActor の UI projection から分離する | Accepted; partially superseded by 0006 and 0009 |
| [0003](0003-use-a-shared-codex-app-server.md) | AI runtime | Codex app-server をアプリ共有の長寿命 backend として使う | Accepted |
| [0004](0004-protect-recordings-with-segmented-immutable-storage.md) | Recording storage | 録音データを分割された immutable segment として保全する | Accepted |
| [0005](0005-vault-scoped-meeting-access-mcp.md) | Meeting access | Vault 固定・read-only の local MCP で meeting data を公開する | Accepted |
| [0006](0006-bounded-transcript-projection.md) | Transcript UI | SQLite を正本とし、文字起こし表示を bounded projection と keyset pagination にする | Accepted; partially supersedes 0002 |
| [0007](0007-version-and-restore-sqlite-backups.md) | Database backup | SQLite backup を schema generation 付きで管理する | Accepted |
| [0008](0008-render-streaming-chat-markdown-as-bounded-projection.md) | Chat UI | Streaming Markdown を bounded UI projection として描画する | Accepted |
| [0009](0009-execution-context-and-degradation-order.md) | Concurrency / UI responsiveness | 実行コンテキストの判断基準と負荷時の縮退順序を定める | Accepted; partially supersedes 0002 |

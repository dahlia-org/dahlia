# Architecture Decision Records

ADR は、設計判断を行った時点の背景、選択肢、トレードオフを残す履歴である。
現在の構成、横断的な設計原則、実装との適合状況、修正完了条件は
[ARCHITECTURE.md](../../ARCHITECTURE.md)、機能の採否と scope の境界は
[PRODUCT.md](../../PRODUCT.md) を正本とする。
product tenet 自体を変更または追加する場合も、その判断は新しい ADR に記録する。

Codex は全 ADR を順番に読まず、最初にこの一覧から現在の作業に関係する記録だけを選ぶ。
既存の決定を変更または反転する場合は、新しい ADR を追加して置換関係を記録し、過去の本文を現在形へ書き換えない。

| ADR | Area | Decision | Status / relationship |
| --- | --- | --- | --- |
| [0001](0001-summary-document-ast.md) | Summary | `SummaryDocument` AST をサマリーの正準表現にする | Accepted |
| [0002](0002-isolate-recording-critical-path-from-main-actor.md) | Recording / Concurrency | 録音と確定データの保存を MainActor の UI projection から分離する | Accepted; partially superseded by 0006 and 0009 |
| [0003](0003-use-a-shared-codex-app-server.md) | AI runtime | Codex app-server をアプリ共有の長寿命 backend として使う | Accepted; amended by 0013, 0015, 0019, 0020, and 0021 |
| [0004](0004-protect-recordings-with-segmented-immutable-storage.md) | Recording storage | 録音データを分割された immutable segment として保全する | Accepted |
| [0005](0005-vault-scoped-meeting-access-mcp.md) | Meeting access | Vault 固定・read-only の local MCP で meeting data を公開する | Accepted; amended by 0010 |
| [0006](0006-bounded-transcript-projection.md) | Transcript UI | SQLite を正本とし、文字起こし表示を bounded projection と keyset pagination にする | Accepted; partially supersedes 0002 |
| [0007](0007-version-and-restore-sqlite-backups.md) | Database backup | SQLite backup を schema generation 付きで管理する | Accepted |
| [0008](0008-render-streaming-chat-markdown-as-bounded-projection.md) | Chat UI | Streaming Markdown を bounded UI projection として描画する | Accepted |
| [0009](0009-execution-context-and-degradation-order.md) | Concurrency / UI responsiveness | 実行コンテキストの判断基準と負荷時の縮退順序を定める | Accepted; partially supersedes 0002 |
| [0010](0010-database-canonical-bounded-project-hierarchy.md) | Project workspace | DB 正本の2段階 Project 階層と派生 Summary 出力先を採用する | Accepted; amends 0005 |
| [0011](0011-vault-scoped-customer-intelligence.md) | Customer intelligence | Vault単位の型付き正準データとAI示唆を分離する | Accepted; amends 0005, builds on 0010 |
| [0012](0012-reviewable-customer-intelligence-workspace.md) | Customer intelligence / UI | 単一顧客の組織ビューと単数 CRUD による逐次AI更新を採用する | Accepted; amends 0011 |
| [0013](0013-expand-codex-stdout-burst-buffer.md) | AI runtime | Codex stdout の burst buffer を拡張し、消費済み payload を即時解放する | Superseded by 0019 |
| [0014](0014-domain-driven-organization-merge.md) | Customer intelligence / Identity | メールドメイン追加を入口にルート組織を完全統合する | Accepted; amends 0011 and 0012 |
| [0015](0015-preset-projects-optimizer-skill.md) | AI runtime / Project workspace | Projects Optimizer skill をアプリ内チャットへプリセットする | Accepted; partially superseded by 0021, amends 0003, builds on 0010 |
| [0016](0016-shared-organization-domains.md) | Customer intelligence / Identity | 同じメールドメインを複数のルート組織で共有可能にする | Accepted; amends 0011 and 0014 |
| [0017](0017-preset-customer-intelligence-skills.md) | AI runtime / Customer intelligence | 顧客インテリジェンスの curator skill を層ごとに分けてプリセットする | Accepted; amends 0015, builds on 0011 and 0012 |
| [0018](0018-mcp-meeting-summary-update.md) | Summary / Meeting access | サマリーの訂正を MCP のドキュメント全体置換で行う | Accepted; amends 0005 and 0010, builds on 0001 |
| [0019](0019-pull-codex-stdout-with-backpressure.md) | AI runtime | Codex stdout を64 KiB単位で需要駆動読み取りする | Accepted; supersedes 0013, amends 0003; amended by 0020 |
| [0020](0020-bound-codex-output-relative-to-client-input.md) | AI runtime | Codex stdout の単一行上限をclient入力に応じて拡張する | Accepted; amends 0019 and 0003 |
| [0021](0021-preserve-user-home-for-databricks-authentication.md) | AI runtime / Authentication | app-server では `CODEX_HOME` だけを分離し、Databricks CLI のため user `HOME` を継承する | Accepted; partially supersedes 0015, amends 0003 |
| [0022](0022-unify-main-window-navigation-and-evidence-inspector.md) | Main window / Recording UI / Transcript evidence | 3列ナビゲーション、役割別Inspector、DB-backed参照ジャンプ、録音停止配置を統合する | Accepted; builds on 0006 and 0009 |

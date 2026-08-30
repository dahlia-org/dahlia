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
| [0001](0001-summary-document-ast.md) | Summary | `SummaryDocument` AST をサマリーの正準表現にする | Accepted; amended by 0024 |
| [0002](0002-isolate-recording-critical-path-from-main-actor.md) | Recording / Concurrency | 録音と確定データの保存を MainActor の UI projection から分離する | Accepted; partially superseded by 0006 and 0009 |
| [0003](0003-use-a-shared-codex-app-server.md) | AI runtime | Codex app-server をアプリ共有の長寿命 backend として使う | Accepted; amended by 0013, 0015, 0019, 0020, 0021, 0022, 0028, 0032, and 0039 |
| [0004](0004-protect-recordings-with-segmented-immutable-storage.md) | Recording storage | 録音データを分割された immutable segment として保全する | Accepted |
| [0005](0005-vault-scoped-meeting-access-mcp.md) | Meeting access | Vault 固定・read-only の local MCP で meeting data を公開する | Accepted; amended by 0010, 0034, and 0041 |
| [0006](0006-bounded-transcript-projection.md) | Transcript UI | SQLite を正本とし、文字起こし表示を bounded projection と keyset pagination にする | Accepted; partially supersedes 0002 |
| [0007](0007-version-and-restore-sqlite-backups.md) | Database backup | SQLite backup を schema generation 付きで管理する | Accepted |
| [0008](0008-render-streaming-chat-markdown-as-bounded-projection.md) | Chat UI | Streaming Markdown を bounded UI projection として描画する | Accepted |
| [0009](0009-execution-context-and-degradation-order.md) | Concurrency / UI responsiveness | 実行コンテキストの判断基準と負荷時の縮退順序を定める | Accepted; partially supersedes 0002 |
| [0010](0010-database-canonical-bounded-project-hierarchy.md) | Project workspace | DB 正本の2段階 Project 階層と派生 Summary 出力先を採用する | Accepted; amends 0005 |
| [0011](0011-vault-scoped-customer-intelligence.md) | Customer intelligence | Vault単位の型付き正準データとAI示唆を分離する | Accepted; amends 0005, builds on 0010 |
| [0012](0012-reviewable-customer-intelligence-workspace.md) | Customer intelligence / UI | 単一顧客の組織ビューと単数 CRUD による逐次AI更新を採用する | Accepted; amends 0011; amended by 0022 and 0027 |
| [0013](0013-expand-codex-stdout-burst-buffer.md) | AI runtime | Codex stdout の burst buffer を拡張し、消費済み payload を即時解放する | Superseded by 0019 |
| [0014](0014-domain-driven-organization-merge.md) | Customer intelligence / Identity | メールドメイン追加を入口にルート組織を完全統合する | Accepted; amends 0011 and 0012 |
| [0015](0015-preset-projects-optimizer-skill.md) | AI runtime / Project workspace | Projects Optimizer skill をアプリ内チャットへプリセットする | Accepted; partially superseded by 0021, amends 0003, builds on 0010; amended by 0028 |
| [0016](0016-shared-organization-domains.md) | Customer intelligence / Identity | 同じメールドメインを複数のルート組織で共有可能にする | Accepted; amends 0011 and 0014 |
| [0017](0017-preset-customer-intelligence-skills.md) | AI runtime / Customer intelligence | 顧客インテリジェンスの curator skill を層ごとに分けてプリセットする | Accepted; amends 0015, builds on 0011 and 0012; amended by 0028 |
| [0018](0018-mcp-meeting-summary-update.md) | Summary / Meeting access | サマリーの訂正を MCP のドキュメント全体置換で行う | Accepted; amends 0005 and 0010, builds on 0001; amended by 0024 |
| [0019](0019-pull-codex-stdout-with-backpressure.md) | AI runtime | Codex stdout を64 KiB単位で需要駆動読み取りする | Accepted; supersedes 0013, amends 0003; amended by 0020 |
| [0020](0020-bound-codex-output-relative-to-client-input.md) | AI runtime | Codex stdout の単一行上限をclient入力に応じて拡張する | Accepted; amends 0019 and 0003 |
| [0021](0021-preserve-user-home-for-databricks-authentication.md) | AI runtime / Authentication | app-server では `CODEX_HOME` だけを分離し、Databricks CLI のため user `HOME` を継承する | Accepted; partially supersedes 0015, amends 0003; amended by 0039 |
| [0022](0022-user-approved-workspace-write-chat.md) | AI runtime / Chat | アプリ内チャットを `workspace-write` とユーザー承認で実行する | Accepted; amends 0003 and 0012; amended by 0023, 0027, and 0036 |
| [0023](0023-review-vault-mcp-writes-in-chat.md) | AI runtime / Chat / MCP | Vault MCP の書き込みを追加権限なしの単一 tool call として承認する | Accepted; amends 0022 |
| [0024](0024-flat-summary-blocks-with-hierarchy-attributes.md) | Summary / Meeting access | 平坦な階層属性でサマリーのネストリストと表を表現する | Accepted; amends 0001 and 0018 |
| [0025](0025-adopt-allowlisted-nonblocking-telemetry.md) | Privacy / Observability | 許可リスト制の匿名テレメトリを公式 SDK の非ブロッキング経路で送る | Accepted; amended by 0026 |
| [0026](0026-measure-product-adoption-with-bounded-telemetry.md) | Privacy / Product analytics | 丸めた録音時間と AI chat・内蔵 MCP の利用を固定 allowlist で計測する | Accepted; amends 0025; amended by 0028 |
| [0027](0027-use-provider-aware-chat-approval-reviewer.md) | AI runtime / Chat / Authentication | ChatGPT Subscription は代理審査、Databricks はユーザー承認を使う | Accepted; amends 0012 and 0022; builds on 0023; amended by 0036 |
| [0028](0028-remove-automatic-previous-meeting-summary-context.md) | Summary / AI runtime / MCP | 要約生成の過去 meeting 自動参照と要約専用 MCP session を廃止する | Accepted; amends 0003, 0015, 0017, and 0026 |
| [0029](0029-offer-an-optional-codex-ai-gateway.md) | AI runtime / Server gateway | 内蔵 Codex 用の任意の認証付き AI Gateway を別 runtime で提供する | Accepted; amends 0003; amended by 0031, 0043, 0044, 0045, 0046, and 0047 |
| [0031](0031-publish-dahlia-server-extension-contract.md) | Server gateway / Distribution | 実行可能な Server と versioned extension contract を同じ package で配布する | Accepted; amends 0029; amended by 0043 |
| [0032](0032-use-local-codex-login-success-page.md) | AI runtime / Authentication | ChatGPT 認証完了に app-server のローカル成功ページを使う | Accepted; amends 0003 |
| [0033](0033-use-local-fts5-search-projection.md) | Search / Database projection | Lindera と FTS5 による再構築可能なローカル検索索引を使う | Accepted; builds on 0006, 0007, and 0009; amended by 0034, 0040, and 0041 |
| [0034](0034-index-summary-body-in-local-search.md) | Search / Summary | 構造化 summary の本文をローカル検索対象にする | Accepted; amends 0005 and 0033, builds on 0001; amended by 0040 |
| [0035](0035-add-local-hybrid-search.md) | Search / ML | 任意導入の256次元 EmbeddingGemma 索引でローカルハイブリッド検索を提供する | Accepted; amends 0033 and 0034; amended by 0037 and 0041 |
| [0036](0036-select-chat-approval-method-per-task.md) | AI runtime / Chat / Authentication | AI チャットの承認方法をタスクごとに選択する | Accepted; amends 0022 and 0027; builds on 0023 |
| [0037](0037-use-actual-summary-content-for-meeting-vectors.md) | Search / ML / Summary | meeting vector を title と実際の summary コンテンツに限定する | Accepted; amends 0035, builds on 0001 and 0034; amended by 0041 |
| [0038](0038-index-screenshot-ocr-in-local-search.md) | Search / Screenshots | 全 screenshot の検出文字と画像説明を正本保存し独立した FTS 結果として返す | Accepted; amends 0005, 0033, and 0035 |
| [0039](0039-guide-databricks-cli-installation-and-login.md) | AI runtime / Authentication / Distribution | CLI を外部導入のまま案内し、workspace URL から OAuth profile を作成する | Accepted; amends 0003 and 0021 |
| [0040](0040-user-configurable-meeting-search-field-weights.md) | Search / Settings | ミーティング検索の順位をユーザー設定のフィールド重みで決める | Accepted; amends 0033 and 0034; amended by 0041 |
| [0041](0041-exclude-project-context-from-meeting-search.md) | Search / Project context | Project の文脈をミーティング自由文検索と順位から除外する | Accepted; amends 0005, 0033, 0035, 0037, and 0040; builds on 0034 |
| [0042](0042-apply-global-batch-audio-retention.md) | Recording storage / Settings | 現在の保存期間と録音終了日時からバッチ録音を遡及削除する | Accepted; amends 0004 |
| [0043](0043-unify-dahlia-server-application-database.md) | Server gateway / Database | Server の認証・管理・将来同期を単一の選択可能な Drizzle DB に統一する | Accepted; amends 0029 and 0031; amended by 0044 |
| [0044](0044-deploy-dahlia-server-to-databricks-apps.md) | Server gateway / Databricks | DAB、Lakebase、App OAuth で Dahlia Server を Databricks Apps に配置する | Accepted; amends 0029 and 0043; amended by 0045, 0046, and 0047 |
| [0045](0045-add-owner-scoped-artifact-transport.md) | Server / Artifact storage | owner-scoped の任意 asset transport を R2 または Volume で提供する | Accepted; amends 0029, 0043, and 0044; amended by 0048 |
| [0046](0046-forward-databricks-user-token-to-ai-gateway.md) | Server gateway / Databricks | Apps proxy の user token で workspace AI Gateway を呼ぶ | Accepted; amends 0029 and 0044 |
| [0047](0047-manage-pnpm-dependencies-per-application.md) | Server gateway / Distribution | モノレポ内の各アプリが pnpm manifest と lockfile を独立して所有する | Accepted; amends 0029 and 0044 |
| [0048](0048-issue-artifact-ids-server-side.md) | Server / Artifact API | UUIDv7 artifact ID を Server で発行し、PUT を置換専用にする | Accepted; amends 0045 |
| [0049](0049-expose-artifact-tools-over-remote-mcp.md) | Server / MCP / Authentication | owner-scoped artifact mutation を remote MCP として公開する | Accepted; amends 0029, 0044, 0045, and 0048 |

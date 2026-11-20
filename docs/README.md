# Dahlia Documentation

Dahlia は Desktop、Server / Private Web、公開サイトを持つモノレポ。目的と対象から正本を選ぶ。

## 現在の仕様・操作

| 対象 | 読む文書 | 内容 |
| --- | --- | --- |
| 全体 | [Product](../PRODUCT.md) | 機能の採否、tenet、AI と人の役割 |
| 全体・runtime 境界 | [Architecture](../ARCHITECTURE.md) | ownership、同期境界、Desktop の信頼性・応答性、適合状況 |
| Desktop | [README](../README.md) / [日本語](../README_ja.md) | macOS の導入・ビルド・利用 |
| Desktop | [音声・文字起こし](architecture/audio-transcription-data-flow.md) | capture、保存、開始・停止・異常時の data flow |
| Desktop | [Project workspaces](project-workspaces.md) | ローカル Project、Workspace、MCP の操作契約 |
| Desktop / Server | [MCP transcript access](live-mcp.md) | 全ワークスペースの読み書き、確定文字起こしの差分取得と待機（日英） |
| Desktop / Server | [Conversation analytics](conversation-analytics.md) | 会話分析のモデルと操作 |
| Desktop | [Calendar schema](calendar-event-schema.md) | 予定のキーと Meeting との関係 |
| Desktop | [Telemetry](telemetry.md) / [Release versioning](desktop-release-versioning.md) | 匿名収集規則、desktop release の版管理 |
| Desktop | [Logs](desktop-logs.md) | ファイルログと OSLog の採取手順、ログ追加の規則 |
| Desktop（Electron alpha） | [Electron README](../apps/desktop/README.md) | オンライン専用の開発用アルファの起動・構成・制限 |
| Desktop v2（Electron） | [Desktop v2 README](../apps/desktop-v2/README.md) | 録音・Mac での文字起こし・要約だけの独立した開発版 |
| Server / Private Web | [Server README](../apps/server/README.md) | API、認証・認可、Workspace 共有、検索、設定、開発 |
| Server / Cloud | [Deployment](../deploy/README.md) | 配置方法の入口 |
| Server / Cloud | [Cloudflare](../deploy/cloudflare/README.md) / [Databricks](../deploy/databricks/README.md) | 配置先ごとの手順・制約 |
| 公開サイト | [Site README](../apps/site/README.md) | site の開発・配布 |

## テーマ別の契約と計画

| 文書 | 扱い |
| --- | --- |
| [Spec index](spec/README.md) | `desktop` / `server` / `shared` / `monorepo` 別の現在の契約。テーマ名・見出しから選ぶ |
| [Plans](plans/README.md) | 進行中の実装計画。現行仕様の正本ではない |

## 開発時の指示

[Root AGENTS.md](../AGENTS.md) から変更対象の scoped guide へ進む。[Code review](code-review.md) は全 runtime の共通基準、[Agent instructions](agent-instructions.md) は指示ファイル自体の保守方針。

## 文書の書き方

文書は現在の契約だけを現在形で書く。変わった部分は本文を書き換え、変更の理由と経緯は commit message と pull request に書く。

- 一つの事実は一か所に書き、ほかの文書からはリンクする。README・計画・仕様に同じ説明を複製しない。
- 仕様には、守る契約、未適合・未検証の事項、再提案されそうな却下した案を分けて書く。契約とコードが違うときは、文書をコードに合わせず未適合として書く。
- 日付は、ユーザーが承認した日と計測した日に書く。
- 廃止した機能の仕様は、残る制約を生きている仕様へ移してから削除する。計画と調査も、未解決事項・根拠と限界を仕様へ移してから削除する。原文は git の履歴で辿れる。
- 新しい文書は冒頭に対象と役割を書き、最寄りの索引（README.md）に登録する。
- `node scripts/check-docs.mjs` がリンク切れ、端末固有の絶対パス、索引への未登録、`docs/spec/` 内の改訂履歴の語を検査する。

API の具体的な操作・旧→新対応・プロトコル委譲は [Server API audit](architecture/server-api-audit.md)、契約は [OpenAPI の仕様](spec/server/openapi.md) を参照する。

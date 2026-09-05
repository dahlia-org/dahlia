# Dahlia Documentation

Dahlia は Desktop、Server / Private Web、公開サイトを持つモノレポ。目的と対象から正本を選び、ADR や調査を現在の仕様と混同しない。

## 現在の仕様・操作

| 対象 | 読む文書 | 内容 |
| --- | --- | --- |
| 全体 | [Product](../PRODUCT.md) | 機能の採否、tenet、AI と人の役割 |
| 全体・runtime 境界 | [Architecture](../ARCHITECTURE.md) | ownership、同期境界、Desktop の信頼性・応答性、適合状況 |
| Desktop | [README](../README.md) / [日本語](../README_ja.md) | macOS の導入・ビルド・利用 |
| Desktop | [音声・文字起こし](architecture/audio-transcription-data-flow.md) | capture、保存、開始・停止・異常時の data flow |
| Desktop | [Project workspaces](project-workspaces.md) | ローカル Project、Vault、MCP の操作契約 |
| Desktop | [Customer intelligence](customer-intelligence-workspace.md) / [Conversation analytics](conversation-analytics.md) | 顧客情報、Insight、Topic のモデルと操作 |
| Desktop | [Calendar schema](calendar-event-schema.md) | 予定のキーと Meeting との関係 |
| Desktop | [Telemetry](telemetry.md) / [Release versioning](desktop-release-versioning.md) | 匿名収集規則、desktop release の版管理 |
| Server / Private Web | [Server README](../apps/server/README.md) | API、認証・認可、Vault 共有、検索、設定、開発 |
| Server / Cloud | [Deployment](../deploy/README.md) | 配置方法の入口 |
| Server / Cloud | [Cloudflare](../deploy/cloudflare/README.md) / [Databricks](../deploy/databricks/README.md) | 配置先ごとの手順・制約 |
| 公開サイト | [Site README](../apps/site/README.md) | site の開発・配布 |

## 判断の経緯・調査・計画

| 文書 | 扱い |
| --- | --- |
| [ADR index](adr/README.md) | `desktop` / `server` / `shared` / `monorepo` 別の設計判断。テーマ名・見出しから選ぶ |
| [Plans](plans/README.md) | 旧計画の整理先と履歴。完了した手順を実装指示として再利用しない |
| [録音自動停止の調査（2026-07-13）](research/2026-07-13-automatic-recording-stop-investigation.md) | Desktop の過去の障害調査。現在の再現・解消を示すものではない |
| [他アプリの録音停止観測（2026-08-08）](research/2026-08-08-reference-app-recording-stop-observation.md) | 観測日の参考情報。Dahlia の保証ではない |
| [顧客情報モデルの調査（2026-07-26）](research/2026-07-26-customer-intelligence-ontology-and-insights.md) | 採否の根拠。現行モデルは機能文書と関連 ADR を参照 |
| [検索ランキング調査（2026-08-25）](research/2026-08-25-meeting-search-ranking-benchmark.md) | 当時のデータ・実験条件に限定した結果。一般的な品質保証ではない |

## 開発時の指示

[Root AGENTS.md](../AGENTS.md) から変更対象の scoped guide へ進む。[Code review](code-review.md) は全 runtime の共通基準、[Agent instructions](agent-instructions.md) は指示ファイル自体の保守方針。

## 文書を増やす前に

現在の契約は上の正本へ追記し、同じ説明を README・計画・ADR に複製しない。新規文書には対象と役割を冒頭に示し、この索引へ登録する。過去の調査は日付と限界を残す。完了した計画は固有の未解決事項を確認したうえで現行資料への案内に縮め、詳細は固定 commit の履歴で辿れるようにする。

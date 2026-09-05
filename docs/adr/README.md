# 設計判断

対象・テーマごとに、採択した設計、その理由、制約と変更の経緯をまとめる。採択は実装・rollout・検証の完了を意味しない。現在の構成と適合状況は [ARCHITECTURE.md](../../ARCHITECTURE.md)、Server の API・運用は [Server README](../../apps/server/README.md)、機能の採否は [PRODUCT.md](../../PRODUCT.md) を参照する。文書全体の入口は [Documentation](../README.md)。

`Codex app-server` は Desktop の内蔵子プロセスであり、Dahlia Server とは別物。

## Desktop

macOS、ローカル SQLite、録音、UI、内蔵 Codex / local MCP。

- [サマリーの構造と更新](desktop/summary.md)
- [録音ストレージと保存期間](desktop/recording-storage.md)
- [実行コンテキストと UI projection](desktop/concurrency-and-projection.md)
- [SQLite backup / restore](desktop/database-backup.md)
- [Local MCP と Project 階層](desktop/local-mcp-and-projects.md)
- [顧客情報の正準モデルと更新](desktop/customer-intelligence.md)
- [内蔵 AI skill と context](desktop/ai-skills-and-context.md)
- [Codex runtime と stdio](desktop/codex-runtime.md)
- [Desktop の認証と account 分離](desktop/accounts.md)
- [チャットの書き込みと承認](desktop/chat-approval.md)
- [匿名 telemetry](desktop/telemetry.md)
- [ローカル全文検索と旧 Hybrid 検索](desktop/search.md)

## Server / Cloud

Server / Private Web、配置、API、認可、storage。

- [AI Gateway と配布契約](server/gateway.md)
- [Databricks 配置と upstream identity](server/databricks.md)
- [Artifact storage / API / MCP / Web](server/artifacts.md)
- [Database schema と認可 identity](server/database-and-identity.md)
- [Vault 共有と管理者](server/sharing-and-administration.md)
- [Server 全文・Hybrid 検索](server/search.md)

## Shared

Desktop / Server / 外部 client 間の契約。

- [Desktop / Server / MCP の OAuth 契約](shared/oauth.md)
- [Desktop / Server の canonical sync](shared/sync.md)
- [Desktop / Gateway の AI timeout](shared/ai-timeouts.md)

## Monorepo

リポジトリ全体の build / package 所有境界。

- [アプリ単位の依存管理](monorepo/dependencies.md)

## 更新のルール

- 番号を付けず、対象とテーマを表すファイル名・見出しで参照する。同じテーマの追補は本文へ統合し、責務や対象が異なる場合だけ文書を増やす。
- 対象、判断の日付、決定、理由、制約を残す。判断が変わった部分は本文を整合させ、以前の選択と変更理由を日付付きで簡潔に記録する。未実装・未検証・未解決事項を採択済みの仕様と混同しない。
- Product tenet の変更はユーザーが承認した新しい設計判断で行う。
- 型定義のコピー、実装の逐次説明、完了した作業リストはコード・テスト・現行仕様へ寄せる。重要な不変条件、却下理由、rollout 制限は圧縮しても残す。
- 単なる不具合修正、定数調整、手順の更新では文書を増やさない。移動・見出し変更時はリポジトリ内の参照も更新する。

## 過去の記録

2026-09-06 に66件の記録を22テーマへ統合し、旧番号と重複した説明を除いた。これは文書整理であり、新しい製品・設計判断ではない。統合前の詳細と旧パスは [Git 履歴の原文](https://github.com/dahlia-org/dahlia/tree/a84967776061c5db1be2e0f25bf135dcdc4e6ba7/docs/adr) で参照できる。

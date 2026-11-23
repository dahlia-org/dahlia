# Specs

テーマごとの現在の契約を置く。各仕様は、守る契約、未適合・未検証の事項、再提案されそうな却下した案を分けて書く。採択は実装・rollout・検証の完了を意味しない。現在の構成と横断的な適合状況は [ARCHITECTURE.md](../../ARCHITECTURE.md)、機能の採否は [PRODUCT.md](../../PRODUCT.md)、Server の API・運用は [Server README](../../apps/server/README.md) を参照する。文書全体の入口は [Documentation](../README.md)。

内蔵 Pi は Desktop の子プロセスであり、Dahlia Server とは別物。

## Desktop

macOS、ローカル SQLite、録音、UI、内蔵 Pi / local MCP。

- [録音ストレージと保存期間](desktop/recording-storage.md)
- [会議の開始通知と録音の自動停止](desktop/recording-auto-stop.md)
- [実行コンテキストと UI projection](desktop/concurrency-and-projection.md)
- [サマリーの構造と更新](desktop/summary.md)
- [ローカル全文検索](desktop/search.md)
- [Workspace archive backup / restore](desktop/database-backup.md)
- [Local MCP と Project 階層](desktop/local-mcp-and-projects.md)
- [Desktop の認証と account 分離](desktop/accounts.md)
- [内蔵 Pi runtime](desktop/pi-runtime.md)
- [内蔵 AI skill と context](desktop/ai-skills-and-context.md)
- [Desktop Pi のメモリーと自己学習](desktop/pi-self-learning.md)
- [アプリが開いている間の定期エージェント](desktop/scheduled-agent-scope.md)
- [チャットのスレッド管理と画面に依存しない実行](desktop/chat-thread-orchestration.md)
- [チャットの書き込みと承認](desktop/chat-approval.md)
- [エージェントによる MCP 経由の外部サービス操作](desktop/agent-mcp-operations.md)
- [匿名 telemetry](desktop/telemetry.md)
- [Electron アルファ版](desktop/electron-alpha.md)
- [Desktop v2（Electron、独立実装）](desktop/electron-v2.md)

## Server / Cloud

Server / Private Web、配置、API、認可、storage。

- [Server database と認可 identity](server/database-and-identity.md)
- [Workspace 共有と管理者](server/sharing-and-administration.md)
- [Server Workspace content encryption](server/vault-encryption.md)
- [Server API 契約と生成クライアント](server/openapi.md)
- [AI Gateway と配布契約](server/gateway.md)
- [Databricks 配置と upstream identity](server/databricks.md)
- [Server アカウントの要約生成](server/summary-generation.md)
- [Server 全文・Hybrid 検索](server/search.md)
- [Server の Remote MCP](server/remote-mcp.md)
- [Dahlia Memory の個人領域と外部エージェント](server/dahlia-memory.md)
- [Artifact storage / API / MCP / Web（廃止）](server/artifacts.md): 廃止した機能について残る制約

## Shared

Desktop / Server / 外部 client 間の契約。

- [Desktop / Server の canonical sync](shared/sync.md)
- [Organization と Workspace の所有・役割・本人用 Workspace](shared/organization-personal-workspaces.md)
- [Desktop / Server / MCP の OAuth 契約](shared/oauth.md)
- [アカウント別の Desktop 推論と操作元による実行場所](shared/account-scoped-desktop-inference.md)
- [文字起こし・要約の処理場所](shared/transcription-summary-processing.md)
- [録音音声の保存と Server 保管](shared/recording-audio-archive.md)
- [会議 Notes の共同編集 Documents](shared/documents.md)
- [Workspace に属する独立した Document](shared/document-identity.md)
- [Calendar 参加者スナップショットと顧客情報の廃止](shared/calendar-attendee-snapshots.md)
- [会話分析の Server ownership](shared/conversation-analytics.md)
- [Desktop / Gateway の AI timeout](shared/ai-timeouts.md)

## Monorepo

- [pnpm workspace と共通 UI の依存管理](monorepo/dependencies.md)

## 書き方

- 現在の契約だけを現在形で書く。変わった部分は本文を書き換え、変更の理由と経緯は commit message と pull request に書く。改訂履歴を表す語は `node scripts/check-docs.mjs` が拒否する。
- 冒頭に対象と、ユーザーが承認した日付を書く。計測値には計測日と条件・限界を添える。
- 契約とコードが違うときは、文書をコードに合わせず「未適合・未検証」に書く。どちらが正しいか分からないものは「未確定」と書く。
- 「却下した案」には、再提案されそうな案だけを、元の理由とともに一行で書く。
- Product tenet の変更は、ユーザーの明示的な承認を得てから行う。
- 一つのテーマは一つのファイルに書き、責務や対象が違う場合だけファイルを分ける。廃止した機能のファイルは、残る制約を生きている仕様へ移してから削除する。移動・見出し変更のときはリポジトリ内のリンクも直す。

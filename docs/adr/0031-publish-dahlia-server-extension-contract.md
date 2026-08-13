# ADR-0031: Dahlia Server の versioned extension contract を公開する

- Status: Accepted
- Date: 2026-08-14
- Amends: ADR-0029

## Context

Dahlia Server はセルフホスト可能な実行アプリケーションである一方、認証済み Gateway の前後へ配置固有の認可、API、Dashboard UI、database migration を追加できる再利用境界も必要になる。実装を fork すると Gateway、認証、streaming、storage adapter の修正が分岐し、同じ wire contract を安全に保てない。

## Decision

- `apps/server` を実行可能アプリケーション兼 `dahlia-ai` package とする。
- package root は Worker-safe な共通 API だけを公開し、Node-only API は `dahlia-ai/node` subpath へ分離する。
- package は macOS アプリとは独立した SemVer を持ち、`server-v<version>` tag から npm へ公開する。
- backend extension は Better Auth plugin、認証前 route、認証済み API route、session capability、Gateway 転送前 hook を追加できる。
- client extension はブランド、navigation、capability で保護された未予約の Dashboard route と React page を追加できる。Server 組み込み route は上書きできない。
- migration manifest は Server の SQLite／PostgreSQL migration を常に先に並べ、extension migration をその後へ合成する。各 directory は順序変更や別 extension の filename に依存しない安定した ledger ID を持ち、SQLite は実行対象 filename を明示する。公開済み migration は変更しない。
- extension は provider secret、request/response content、録音、文字起こし、ローカル database を新しい共有 contract に含めない。
- package consumer は exact version を使用する。公開前の共同開発は `pnpm link`、公開 artifact の確認は `pnpm pack` を使用する。

## Consequences

- セルフホスト利用者は extension なしで従来の Server を起動できる。
- 別 distribution は共通実装を複製せず、明示された hook と migration 順序だけに依存できる。
- extension contract の破壊的変更は package の major version を必要とする。
- Server は extension 固有の dependency、schema、設定、運用 policy を所有しない。

## Relationship

ADR-0029 の Gateway、認証、storage、Responses relay の境界は維持する。この ADR はその実装を reusable package として配布する方法だけを追加する。

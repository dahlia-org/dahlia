# ADR-0043: Dahlia Server の application database を統一する

- Status: Accepted
- Date: 2026-08-28
- Amends: ADR-0029, ADR-0031

## Context

Dahlia Server の Better Auth と Gateway 管理データは配置ごとに異なる実装を持ち、一括 runtime preset が database、認証、AI backend を結合していた。今後 meeting data の cloud sync を追加する際も、認証と同期で別の database contract を増やすべきではない。

## Decision

- Better Auth、Model Alias、platform administrator、および将来追加する meeting sync は単一の application database と migration 順序を共有する。
- database access と migration 管理は Drizzle に統一する。Better Auth schema は生成物、application table は Dahlia 管理の schema 定義とし、SQLite/PostgreSQL の両方を Drizzle Kit から生成する。
- PostgreSQL は Better Auth と application table を同じ `dahlia` schema に置く。migration SQL に schema 修飾を持たせず、runner が schema を作成して `search_path=dahlia` で適用する。
- 初回リリース前の未適用 migration は dialect ごとの単一 baseline に置き換える。リリース後は既存 migration を変更せず、forward-only migration を追加する。
- `DAHLIA_DATABASE_TYPE` は `sqlite`、`postgres`、`lakebase`、`hyperdrive`、`d1` を受け取る。SQLite と PostgreSQL の実体は `DAHLIA_DATABASE_URL` で指定する。
- Node は SQLite、PostgreSQL、Lakebase を、Cloudflare Workers は D1、Hyperdrive、直接 PostgreSQL を実行する。D1 binding は `dahlia_db_prod`、Hyperdrive binding は `HYPERDRIVE` とする。
- Lakebase は PostgreSQL dialect とし、公式 `@databricks/lakebase` package の接続設定と OAuth credential refresh を使う。AppKit 全体は追加しない。
- authentication は `DAHLIA_AUTH_PROVIDER`、AI backend は `OPENAI_API_KEY` と `OPENAI_BASE_URL` で database と個別に設定する。`DAHLIA_RUNTIME`、`DAHLIA_AUTH_DATABASE`、`DAHLIA_AUTH_SQLITE_PATH`、`DATABASE_URL` の旧一括 contract は廃止し、読み取らない。
- header authentication は proxy が検証済み email header を上書きすることを前提とする。Server は CIDR 判定を行わないため、proxy は client 値を除去し、Server への直接到達を防ぐ。
- この変更では meeting schema や sync API を先行実装しない。同期対象、暗号化、競合解決、削除、権限は実装前に別の判断として定義する。

## Consequences

- すべての backend で Better Auth と application data が同じ database と migration contract を使える。
- database と AI provider を独立して交換でき、Cloudflare では D1 と Hyperdrive を選択できる。
- Lakebase credential refresh の独自実装を持たずに済む。
- 選択した database は認証と将来の同期データを含むため、同じ backup、retention、access-control policy の対象になる。
- meeting cloud sync は Dahlia のローカル録音・文字起こし critical path を待たせてはならない。

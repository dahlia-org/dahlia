# ADR-0044: Dahlia Server を Databricks Apps に配置する

- Status: Accepted
- Date: 2026-08-29
- Amends: ADR-0029, ADR-0043

## Context

Dahlia Server を Databricks Apps に配置し、Lakebase と workspace AI Gateway を App の service principal で利用する。Apps proxy が付与する identity、DAB の source layout、Lakebase の所有権、および provider credential を既存の Server contract へ対応させる必要がある。

## Decision

- `deploy/databricks` の DAB が dev/prod の App と Lakebase Autoscaling project を作成し、pnpm workspace に必要な Server source と root manifest だけを同期する。
- App は project の既定 `databricks_postgres` database に `CAN_CONNECT_AND_CREATE` で接続し、接続 service principal が所有する `auth` schema に Better Auth table、`dahlia` schema に application table と migration ledger を作成する。未リリースの PostgreSQL migration はこの構成の初期 baseline に置き換え、以後は追加 migration だけを使う。
- authentication は `DAHLIA_AUTH_TYPE`、canonical origin は `DAHLIA_APP_URL` と fallback の `DATABRICKS_APP_URL`、AI provider は `DAHLIA_AI_BACKEND` で選択する。旧変数名は読み取らない。
- Databricks backend は runtime の `DATABRICKS_HOST`、`DATABRICKS_CLIENT_ID`、`DATABRICKS_CLIENT_SECRET` で短期 OAuth token を取得し、workspace AI Gateway へだけ送信する。provider secret は DAB に持たない。
- header authentication は Apps proxy が上書きする `X-Forwarded-User` を user ID、`X-Forwarded-Preferred-Username` を表示名、`X-Forwarded-Email` を email とする。任意の trusted proxy は利用する forwarded header をすべて除去・上書きし、Server への直接到達を防ぐ。
- Node origin は HTTP/1.1 で listen する。外部の HTTP/2 または HTTP/3 は配置先の edge proxy が終端する。

## Consequences

- App service principal が database と AI Gateway の credential を所有し、利用者や bundle に provider secret を配布しない。
- Databricks Apps 以外の Node と Cloudflare 配置は同じ application API を保ち、database、authentication、AI backend を独立して選べる。
- 初期 baseline より前の開発用 PostgreSQL schema は移行対象にせず、必要なら削除して再作成する。

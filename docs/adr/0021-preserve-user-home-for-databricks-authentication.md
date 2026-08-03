# ADR 0021: Databricks 認証のため app-server に user HOME を継承する

- Status: Accepted
- Date: 2026-08-04
- Partially supersedes: ADR 0015
- Amends: ADR 0003

## Context

ADR 0015 は、Dahlia の preset skills だけを discovery 対象にするため、Codex app-server 子 process の
`CODEX_HOME` と `HOME` をどちらも Dahlia 専用 `CODEX_HOME` に固定した。

Databricks provider の auth command は app-server から `databricks auth token` を起動する。Databricks CLI は
実ユーザーの `HOME` を使って profile と credential context を解決するため、`HOME` を Dahlia 専用領域へ
差し替えると、設定画面で検証済みの profile でも app-server からは未認証になる。

## Decision

- app-server 子 process には Dahlia 専用 `CODEX_HOME` を設定するが、`HOME` は実ユーザーの値を継承する。
- Databricks provider の auth command は `HOME` を上書きせず、`databricks auth token` を直接実行する。
- config、OpenAI auth、logs、sessions、preset skills の ownership は引き続き Dahlia 専用 `CODEX_HOME` に置く。
  `~/.codex` の state は参照しない。
- user `HOME` の継承により `$HOME/.agents/skills` も discovery 対象になり得ることは、Databricks 認証を
  復旧するための既知のトレードオフとして当面許容する。認証を維持したまま user skill discovery を分離する
  後続対応は [GitHub Issue #234](https://github.com/dahlia-org/dahlia/issues/234) で追跡する。
- summary thread の skills 無効化、Dahlia MCP の Vault 境界、chat の tool policy は変更しない。

## Consequences

- app-server の Databricks auth command は、設定画面の Databricks CLI と同じ profile と credential context を
  参照できる。
- `$HOME/.agents/skills` が chat の discovery 対象になる可能性がある。これらは Dahlia が同梱・監査する
  preset ではないため、Dahlia MCP の validation と tool policy を最終 authority とする。
- launcher の実 process test で、`CODEX_HOME` が専用領域を指し、`HOME` が親 process の値を維持することを
  検証する。

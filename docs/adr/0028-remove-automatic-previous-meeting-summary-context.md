# ADR-0028: 要約生成の過去 meeting 自動参照を廃止する

## Status

Accepted

## Date

2026-08-14

## Context

要約生成は、同じカレンダー予定系列の過去 meeting を自動選択し、meeting 限定の Dahlia MCP process から保存済み要約を取得していた。この機能はほぼ利用されず、選択情報、tool instruction、取得結果が要約の context を消費する。一方、過去 meeting は外部 MCP client またはアプリ内 Codex chat から必要なときに明示的に参照できる。

## Decision

- 要約生成は過去 meeting を自動選択または取得しない。
- 要約 thread は Codex 全体の MCP 設定を書き換えず、既存の restricted config で全 MCP server と tool を無効にする。
- 要約専用の meeting 制限 MCP mode と、その tool call を表す `summary` telemetry origin を廃止する。
- 通常の Vault-scoped read-only MCP と、書き込みを許可したアプリ内 Codex chat の MCP contract は維持する。

## Consequences

良い影響:

- 要約 prompt と生成 context が小さくなり、過去 meeting 取得の追加 tool call がなくなる。
- 要約 thread の tool policy が「全 tool 無効」に統一される。
- 過去 meeting の利用は、ユーザーが必要性を判断した明示的な MCP 操作に限定される。

トレードオフ:

- 定例会議の過去経緯は要約へ自動反映されない。
- 過去経緯を含む分析は、外部 MCP client またはアプリ内 Codex chat で別途行う必要がある。

## Relationship

ADR-0003 の要約 thread で tool と MCP を無効にする判断へ戻し、ADR-0015 と ADR-0017 が維持していた Meeting 限定 MCP の要約契約を置き換える。ADR-0026 の内蔵 summary MCP telemetry は廃止し、その他の匿名 telemetry allowlist と非ブロッキング要件は維持する。

## References

- [ADR-0003](0003-use-a-shared-codex-app-server.md)
- [ADR-0015](0015-preset-projects-optimizer-skill.md)
- [ADR-0017](0017-preset-customer-intelligence-skills.md)
- [ADR-0026](0026-measure-product-adoption-with-bounded-telemetry.md)
- [Telemetry policy](../telemetry.md)

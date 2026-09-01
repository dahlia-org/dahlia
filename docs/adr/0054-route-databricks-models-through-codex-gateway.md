# ADR-0054: Databricks model を Codex Gateway 経由で呼び出す

- Status: Accepted
- Date: 2026-09-01
- Amends: ADR-0044, ADR-0046

## Context

Dahlia Server は Codex の Responses request を Databricks の汎用 Supervisor API
`/ai-gateway/mlflow/v1` へ中継していた。この経路では DeepSeek などの model service が
Codex の `tools` または `tool_choice` を拒否するため、Dahlia chat を実行できない。

Databricks は Codex を model service と接続する専用 endpoint として
`/ai-gateway/codex/v1` を提供している。また、DeepSeek V4 Flash は Codex の固定 catalog
に含まれないため、Dahlia Server が reasoning effort metadata を補う必要がある。

## Decision

- `DAHLIA_AI_BACKEND=databricks` の Responses request は、model に関係なく
  `DATABRICKS_HOST/ai-gateway/codex/v1/responses` へ送る。
- Codex が生成した tool、tool choice、reasoning を削除または変換せず、Databricks の
  coding-agent-specific endpoint に中継する。
- `system.ai.deepseek-v4-flash-0731` は text-only model とし、reasoning effort は
  `low`、`high`、`max`、既定値は `max` として Codex catalog に公開する。
- alias、認証、forwarded user token、model discovery、および公開 Dahlia API は変更しない。

## Consequences

- DeepSeek を含む Databricks model service が Codex の tool request を利用できる。
- DeepSeek の picker は upstream が実際に受理する三段階だけを表示する。
- Databricks backend は coding-agent-specific endpoint の可用性と互換性に依存する。
- 未知 model の capability は引き続き保守的な fallback となり、必要になった model だけを
  固定 Codex version と合わせて追加する。

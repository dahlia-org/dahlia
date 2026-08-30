# ADR-0027: チャットの承認 reviewer を AI provider に合わせる

## Status

Accepted

## Date

2026-08-13

## Context

ADR-0012 は ChatGPT Subscription で利用できる Codex の `auto_review` に承認判断を任せていたが、
ADR-0022 は Databricks AI Gateway で reviewer 用モデル呼び出しが利用できないことを受け、すべての provider で
`approvalsReviewer: user` を指定した。この共通化により Databricks でも書き込みを実行できる一方、ChatGPT Subscription
でも command、file change、MCP write tool ごとにユーザー操作が必要になった。

Codex app-server 0.146.0 は `approvalPolicy: on-request` のまま、ターンごとに `approvalsReviewer` を指定できる。
ChatGPT Subscription では代理審査を利用できるため、Databricks の制約を全 provider に適用する必要はない。

## Decision

- アプリ内 AI チャットの各 `turn/start` で、確定済みの provider が ChatGPT Subscription の場合は
  `approvalsReviewer: auto_review` を指定する。
- Databricks、未確定の設定、未知の provider では `approvalsReviewer: user` を指定する。
- provider の選択変更は、設定の検証と app-server の再読み込みが完了した後の次のターンから reviewer に反映する。
- `thread/start` と `thread/resume` の `approvalPolicy: on-request` および `sandbox: workspace-write` は変更しない。
- auto review で処理されず client に届いた承認要求には、ADR-0022 と ADR-0023 の既存 UI、相関、上限、
  fail-closed 処理を適用する。`item/permissions/requestApproval` も引き続き拒否する。
- 要約 thread の `approvalPolicy: never` と `sandbox: read-only` は変更しない。

## Consequences

良い影響:

- ChatGPT Subscription では安全境界を保ったまま、通常のチャット操作に必要な手動承認を減らせる。
- Databricks は利用できない reviewer 用モデル呼び出しに依存せず、従来どおりユーザーが承認できる。
- provider 設定が不明な場合はユーザー承認へ倒れる。

トレードオフ:

- 同じ保存済み thread でも、確定 provider を切り替えた後のターンでは承認主体が変わる。
- ChatGPT Subscription の代理審査には追加のモデル呼び出しが発生しうる。

## References

- ADR-0012: 単一顧客の組織ビューと単数 CRUD による逐次 AI 更新
- ADR-0022: アプリ内チャットを workspace-write とユーザー承認で実行する
- ADR-0023: Vault MCP の書き込みをチャット内で承認する
- `CodexChatService`: `apps/desktop/Sources/Dahlia/Services/CodexChatService.swift`
- account configuration: `apps/desktop/Sources/Dahlia/Services/CodexAppServerService.swift`

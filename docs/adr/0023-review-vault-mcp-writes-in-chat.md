# ADR-0023: Vault MCP の書き込みをチャット内で承認する

## Status

Accepted

## Date

2026-08-05

## Context

Codex app-server 0.146.0 は、承認対象の MCP tool call を既定では `mcpServer/elicitation/request` として client へ送る。
Dahlia はこの request を実装していなかったため `-32601 Client method not supported` を返し、Codex は tool call を
拒否として扱っていた。その結果、読み取りは成功する一方、Project の更新や Meeting assignment などの書き込みは、
ユーザーがチャット本文で承認しても `user rejected MCP tool call` で失敗した。

チャット本文は tool 実行ゲートへの応答ではない。安全に書き込みを成立させるには、対象の MCP item をユーザーへ提示し、
app-server が要求した応答形式で元の JSON-RPC request に返す必要がある。

0.146.0 の MCP elicitation request は item ID を持たない。一方、互換経路の `item/tool/requestUserInput` は item ID を持つ。
Dahlia は Vault 書き込みの承認を、同じ turn の正確な MCP item と相関できる経路だけで提供する。

## Decision

- チャット thread config では `features.tool_call_mcp_elicitation = false` を固定し、MCP tool approval を
  `item/tool/requestUserInput` で受け取る。要約 thread の設定は変更しない。
- `item/tool/requestUserInput` は、question が1件だけで、item ID と `mcp_tool_call_approval_<itemId>` が一致し、固定の
  header、非 secret、非 other、既知の選択肢を持つ MCP approval prompt の場合だけ承認経路へ送る。
- 同じ turn の先行する `item/started` に含まれる `mcpToolCall` を item ID で相関する。server が `dahlia` であり、
  server、tool、arguments を完全に表示できる場合だけ「今回のみ許可」を提示する。
- 相関 snapshot は作成時に合計 20 KB へ制限し、未加工の arguments を cache に保持しない。上限を超えた request、
  相関情報が欠ける request、未知の server は許可しない。JSON の bidi formatting control は `\\uXXXX` 表記にして、
  保存される文字列と表示順序の違いによる偽装を防ぐ。
- 「今回のみ許可」は `{ answers: { <questionId>: { answers: ["Allow"] } } }` を返す。拒否、停止、overflow は
  `Cancel` を返す。session または永続許可は UI に提供せず、内部からその decision が渡っても `Cancel` とする。
- `item/permissions/requestApproval` は built-in `request_permissions` による filesystem/network 権限要求であり、
  従来どおり fail-closed とする。承認 UI が sandbox 境界を拡張してはならない。
- command execution と file change の承認形式、未知の thread に対する fail-closed 処理は変更しない。
- turn 完了、停止、overflow では、command/file approval と同様に未応答の MCP tool approval も必ず解決する。

## Consequences

良い影響:

- AI チャットから Project、Meeting assignment、顧客インテリジェンスを、対象 tool と引数の確認後に更新できる。
- Vault MCP 自体の revision 検査、一件単位の変更、Vault 固定という既存の安全境界を保てる。
- チャット本文での曖昧な承認ではなく、元の tool call に結び付いた明示的な操作になる。

トレードオフ:

- 固定 Codex CLI の互換 approval 経路に依存する。CLI 更新時は feature key、question schema、応答形式を再検証する。
- write tool の呼び出しごとにユーザー操作が必要になる。
- turn ごとに item ID と bounded tool snapshot の一時的な相関状態を保持する。

## References

- ADR-0022: アプリ内チャットを workspace-write とユーザー承認で実行する
- `CodexChatService`: `apps/desktop/Sources/Dahlia/Services/CodexChatService.swift`
- approval routing: `apps/desktop/Sources/Dahlia/Services/CodexAppServerService.swift`
- approval UI: `apps/desktop/Sources/Dahlia/Views/CodexChat/CodexChatApprovalView.swift`

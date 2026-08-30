# ADR-0032: ChatGPT 認証完了にローカル成功ページを使う

- Status: Accepted
- Date: 2026-08-15
- Amends: ADR-0003

## Context

ADR-0003 は ChatGPT の browser login で `useHostedLoginSuccessPage: true` と `appBrand: codex` を指定し、認証完了後に hosted success page を使うことを決定した。Dahlia は返された `authUrl` を既定ブラウザで開き、app-server が受け取るローカル callback と `account/login/completed` notification だけでログイン完了を判定できるため、hosted success page とそのブランド指定は必要ない。

Codex app-server は、`useHostedLoginSuccessPage` を指定しない browser login でローカル成功ページを既定としている。Dahlia は Codex version を固定しており、version 更新時に利用中の request shape と既定値を確認する。

## Decision

- `account/login/start` は `type: chatgpt` だけを指定する。
- `useHostedLoginSuccessPage` と `appBrand` は省略し、app-server のローカル成功ページを使う。
- 返された HTTPS の `authUrl` を開き、対応する `account/login/completed` notification を `loginId` で待つ既存フローは維持する。
- request parameter 全体の完全一致テストで、hosted success page の指定が再追加されないことを検証する。

## Consequences

- 認証完了後に hosted branding page を要求せず、app-server が提供するローカル成功ページで完了する。
- browser login request から不要な optional field がなくなる。
- Codex version 更新時は、ローカル成功ページが引き続き既定であることを protocol schema と認証回帰で確認する必要がある。

## Relationship

ADR-0003 の共有 app-server、専用 `CODEX_HOME`、明示ログイン、HTTPS `authUrl` の検証、`loginId` による完了通知の対応付けは維持する。この ADR は ChatGPT browser login の成功ページ選択だけを変更する。

## References

- [ADR-0003](0003-use-a-shared-codex-app-server.md)
- [OpenAI Codex App Server manual](https://learn.chatgpt.com/docs/app-server.md)
- `apps/desktop/Sources/Dahlia/Services/CodexAppServerService.swift`
- `apps/desktop/Tests/DahliaTests/CodexAppServerServiceTests.swift`

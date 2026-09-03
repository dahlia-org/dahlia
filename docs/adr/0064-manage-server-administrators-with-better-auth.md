# ADR-0064: Server管理者をBetter Auth roleで管理する

- Status: Accepted
- Date: 2026-09-03
- Amends: ADR-0029, ADR-0063

## Context

Server管理者を環境変数とapplication固有tableで管理すると、accountsとheaderでuser directoryと権限の正本が分かれる。
Better Auth admin pluginは標準のuser role、ban、session管理APIを提供する。

## Decision

- Better Auth admin pluginをruntimeとschema生成の両方で有効化し、`auth.user.role`の`admin`を唯一の管理者権限とする。
- 認証方式にかかわらず、最初に作成されたuserを初期adminにする。adminが0人になった場合は次の認証済みrequestで最古userを再昇格する。
- Dahliaの既存`/api/admin/**`と管理画面は同じroleを参照する。accounts modeではBetter Auth標準admin APIも公開する。
- `DAHLIA_ADMIN_EMAIL`とapplication固有のplatform admin tableは廃止する。

## Consequences

- accountsとheaderで管理者の正本とuser IDが共通になる。
- Dahlia APIは最後のadmin降格を拒否するが、Better Auth標準APIの動作は変更しない。
- 未リリースdatabaseは再生成baselineから作成し、旧管理者設定を移行しない。

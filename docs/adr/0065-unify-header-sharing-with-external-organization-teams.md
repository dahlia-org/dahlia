# ADR-0065: Header共有をExternal OrganizationとTeamへ統合する

- Status: Accepted
- Date: 2026-09-03
- Amends: ADR-0057, ADR-0059, ADR-0061, ADR-0063

## Context

Header認証だけdeployment専用principalを持つと、共有、RLS、Web UIがaccounts modeのOrganizationモデルと分岐する。
Header proxyは認証済みuserの集合を提供するため、その集合を通常のOrganization membershipとして射影できる。

## Decision

- Header userを固定ID、slug、nameが`external`のBetter Auth OrganizationへJIT登録する。最初のuserを変更不能なowner、以降をmemberとする。
- `external-default` Teamを初回に作成し、最初のownerだけを自動登録する。このTeamとowner membershipは変更不能とする。OrganizationとTeamは通常のOrganization画面に表示する。
- Better Auth Organization pluginのTeam機能とdefault Teamを有効化する。Accounts modeは標準API、sessionlessなheader modeは同じAuth tableを扱うDahlia APIを使う。
- Vault permission principalを`user | organization | team`に統一し、`header_deployment`を廃止する。OrganizationとTeam permissionはread-onlyで、ownerだけが変更できる。
- RLS contextはtransaction-localな`app.user_id`だけとし、DB関数が`auth.member`と`auth.team_member`を参照する。membership削除は共有readを即時失効させる。
- Header modeではOrganizationの招待、脱退、member削除を提供しない。External Organization ownerだけがTeamとTeam membershipを管理する。
- Organization／Team共有は`DAHLIA_SYNC_SHARING_ENABLED`の明示指定時だけ有効にし、既定は無効とする。無効時もownerの同期とreadは維持する。

## Consequences

- HeaderとaccountsでVault共有とRLSの経路が共通になり、旧deployment全員共有APIは404になる。
- Organization／Team削除hookは対応permissionを除去する。cleanup失敗でstale permissionが残ってもmembershipが消えるためread権限は発生しない。
- Headerからaccountsへ認証方式を変更してもExternal Organizationは自動移行・削除しない。
- 未リリースdatabaseはTeam対応の生成Auth schemaとapplication baselineから再作成する。

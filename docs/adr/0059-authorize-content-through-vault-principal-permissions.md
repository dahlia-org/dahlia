# ADR-0059: Vault principal permission を content 認可の正本にする

- Status: Accepted
- Date: 2026-09-03
- Amends: ADR-0056, ADR-0057, ADR-0058

## Context

同期 v1 は Vault と各 content 行に `owner_workspace_id` を重複保持し、共有 v2 は別の share table を追加した。
この形では owner と member が別の正本になり、content の各行に同じ所有者を複製し続ける必要がある。
Vault が認可境界である以上、principal と role を Vault にだけ結び付ける方が ownership、共有、RLS を一つの規則で表せる。

## Decision

- `core.vault_permissions` を Vault 権限の唯一の正本とする。行は `user`、`organization`、`header_deployment`
  principal と `owner` または `member` role を持つ。
- 各 Vault は変更不能な user owner を一件だけ持つ。partial unique index と check constraint で一意性と principal 種別を保証する。
  organization、header deployment、および将来の直接 user 共有は read-only member とする。
- Vault 作成と owner permission 作成は同じ transaction で行う。既存 Vault への upload は現在 identity と owner permission の一致を
  確認してから受理する。owner 以外の write、delete、permission mutation は存在非開示の 404 とする。
- `core.vaults` と `content.meetings`、`content.transcript_segments`、`content.screenshots` は
  `owner_workspace_id` を持たない。content の親子関係と index は `vault_id` 始まりに統一する。
- PostgreSQL／Lakebase の Vault と content RLS は各行の `vault_id` から `core.vault_permissions` を直接評価する。
  transaction-local contextは`app.user_id`だけとし、ownerは常にread/writeできる。organization permissionはRLS関数が
  `auth.member`を直接参照し、脱退を即時反映する。header deployment permissionはそのdatabaseの認証済みuser全体へ適用する。
  identity context未設定時はdenyする。
- `core.vault_permissions` 自体には RLS を設定しない。permission policy から同じ table を参照する再帰を避け、外部の汎用 query surface
  には公開せず、transaction-scoped identity を受け取る sync store の application 認可だけで保護する。
- public API は `/api/v1/vaults/{vaultId}/permissions` を使用し、旧 `/shares` alias は残さない。Vault read model は
  `owned: boolean` ではなく、複数経路のうち owner を優先した `role: owner | member` を返す。
- SQLite／D1 は同じ permission schema と application predicate を使用する。Better Auth の自動生成 schema は変更しない。

## Consequences

- content ownership の重複列と cross-owner 複合 key が不要になり、Vault permission の変更は同じ Vault の全 content に即時反映される。
- permission table を直接利用できるのは sync store と organization cleanup hook に限る。別の query surface を追加する場合は、同等の
  application 認可を必須とするか、再帰しない別の database security boundary を設計する必要がある。
- 複数 owner、owner 移譲、直接 user member の作成 API／UI、member write、共同編集は今回追加しない。
- 同じdatabaseをaccounts/header認証間で切り替える運用は対象外とする。

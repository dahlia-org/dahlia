# ADR-0058: Server database を auth・core・content schema に分ける

- Status: Accepted
- Date: 2026-09-02
- Amends: ADR-0043, ADR-0044, ADR-0056, ADR-0057

## Context

Dahlia Server の単一 application database に認証、Web application 設定、共有設定、会議本文が増えた。
すべてを `dahlia` schema に置くと、生成物である Better Auth、共有の設定、容量の大きい同期 content の所有境界と
参照方向が分かりにくい。Server はまだリリース前であり、開発 database を再作成して migration baseline を整理できる。

Databricks Asset Bundle も legacy artifact 用 resource 名と dev/prod ごとの schema 名を残しており、実行者が catalog を
選ぶ運用と一致していない。

## Decision

- PostgreSQL／Lakebase は単一 database の中を次の schema に分ける。
  - `auth`: 自動生成した Better Auth table。
  - `core`: Model Alias、platform administrator、artifact metadata、個人所有 Vault、Vault share など Server application の設定。
  - `content`: `meetings`、`transcript_segments`、`screenshots` など同期された実データ。
- 参照は `auth <- core <- content` の方向だけを許可する。すなわち `auth` は Dahlia schema を参照せず、`core` は
  `content` を参照せず、`content` は `core` を参照できる。RLS policy の membership 判定もこの方向を逆転させない。
- Better Auth の生成 schema は編集しない。SQLite／D1 は schema namespace を持たないため、Better Auth table は従来どおり
  top-level に置き、Dahlia table は `core_` と `content_` prefix で境界を表す。
- PostgreSQL の artifact、Vault、meeting、transcript segment、screenshot ID は native `uuid` とする。owner workspace ID、
  Better Auth ID、transcript generation hash は意味上 UUID ではないため `text` のままにする。SQLite／D1 は canonical UUID を
  application boundary で検証して `text` に保存する。
- content table は Desktop の語彙に合わせて `meetings`、`transcript_segments`、`screenshots` の複数形に統一する。
- Server-side Project は必要になるまで作らない。将来、Web application の共有・整理単位として追加する場合は `core` に置く。
  Desktop の project context は引き続き同期対象外とする。
- 未リリース migration は dialect ごとの単一 baseline に置き換える。Better Auth organization table と permission table は常設し、
  明示permissionの有無を共有の唯一の正本とする。
- DAB の managed Volume resource key は `dahlia_storage`、既定名は `storage` とする。Unity Catalog の既定は
  catalog `dahlia`、schema `server` とし、dev/prod の切り替えは実行者が catalog variable で行う。

## Consequences

- content は core の Vault を参照し、core の share policy は auth の membership を参照するが、逆向きの foreign key や query は持たない。
- migration ledger は `core` に置き、PostgreSQL connection の search path は `core,content,auth` とする。security policy と
  foreign key は schema-qualified name を使う。
- 既存の開発 database と Volume は自動移行しない。新 baseline と `dahlia_storage` を使う環境は再作成し、必要な test data だけを再投入する。

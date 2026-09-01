# ADR-0055: artifact の一覧・表示ページを追加する

- Status: Accepted
- Date: 2026-09-01
- Amends: ADR-0045, ADR-0048, ADR-0049

## Context

Artifact REST API と MCP は owner-scoped の作成、置換、公開範囲変更、削除、bytes 読み取りを提供するが、
利用者が書き出し済み artifact をブラウザで一覧・確認する経路がない。Dahlia Server の SPA は browser session を
使う一方、private artifact API は OAuth access token だけを受け付けるため、そのままでは同一 origin の viewer から
private bytes を表示できない。

## Decision

- `/artifacts` に current personal workspace の artifact 一覧、`/artifacts/{artifact_id}` に表示ページを置く。public は
  匿名、private は owner だけが表示できる。
- `GET /api/v1/artifacts` は owner-scoped の metadata を UUIDv7 降順、50件単位の keyset pagination で返す。public
  artifact の横断一覧は作らない。
- Artifact read は `Authorization` header があれば OAuth token だけを検証し、不正 token から browser session へ
  fallback しない。header がなければ browser session を使う。public read は従来どおり匿名を許可する。
- 既存 `GET /api/v1/artifacts/{artifact_id}` の bytes response は維持する。同じ endpoint に
  `Accept: application/vnd.dahlia.artifact+json` を送ると metadata を返し、明示的な bytes endpoint として
  `GET|HEAD /api/v1/artifacts/{artifact_id}/content` も提供する。
- Browser session は read にだけ追加する。artifact mutation は既存の OAuth または trusted proxy identity を維持し、
  browser mutation が必要になるまで cookie と CSRF surface を増やさない。
- 人が共有する正準 URL は `/artifacts/{artifact_id}` とする。MCP resource link は content endpoint を指し、storage URL
  と credential は引き続き公開しない。

## Consequences

- 利用者は追加の token 管理なしで自分の書き出しを確認でき、public viewer URL をそのまま共有できる。
- 一覧 API は owner の metadata だけを返し、artifact 名、説明、検索、履歴、指定ユーザー共有は追加しない。
- 本変更では migration を追加しないため、一覧は既存の artifact ID index を使う。owner をまたぐ artifact 数が増えて
  query scan が問題になった時点で `(owner_workspace_id, id)` の複合 index を追加する。
- API client の既存 raw GET は変わらない。metadata client は vendor media type、viewer は `/content` を明示して表現の
  曖昧さを避ける。

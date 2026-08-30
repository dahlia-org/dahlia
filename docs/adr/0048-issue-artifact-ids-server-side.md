# ADR-0048: artifact ID を Server で発行する

- Status: Accepted
- Date: 2026-08-30
- Amends: ADR-0045

## Context

ADR-0045 の client-supplied UUID と reservation tombstone は、削除済み public URL の再取得を防ぐ一方、永続 table と client 側の ID 管理を必要とする。新規作成を Server に限定すれば、利用者が過去の ID を指定して再取得する経路自体をなくせる。

## Decision

- `POST /api/v1/artifacts` が raw bytes を受け取り、Server が RFC 9562 準拠の lowercase UUIDv7 を発行する。成功時は `201`、artifact metadata、および正準 artifact URL の `Location` header を返す。
- `PUT /api/v1/artifacts/{artifact_id}` は owner による既存 artifact の置換だけを行い、存在しない ID を作成しない。item API は UUIDv7 だけを受け付ける。
- UUIDv7 は Web Crypto の乱数を使い、Node と Worker で同じ生成処理を共有する。追加 dependency や同一 millisecond 内の単調化 counter は導入しない。
- `artifact_reservation` table と永久 tombstone を廃止する。POST は非冪等とし、`Idempotency-Key` は利用実績から必要性が判明するまで追加しない。

## Consequences

- client は ID を生成せず、POST response の ID または `Location` を後続操作に使う。
- 削除済み URL の再取得は、Server が同じ UUIDv7 を偶発的に再生成した場合に限られる。74 bit の乱数により通常運用では無視できる。
- UUIDv7 から作成時刻を millisecond 精度で推定できる。artifact ID は秘密情報として扱わず、private access は従来どおり認証と owner checkで保護する。

# ADR-0045: owner-scoped artifact transport を追加する

- Status: Accepted
- Date: 2026-08-29
- Amends: ADR-0029, ADR-0043, ADR-0044

## Context

Dahlia 内で生成した HTML などの asset を、安定した Server URL から必要な相手へ公開したい。これは Google Drive export と同じ任意の出力経路であり、録音、文字起こし、SQLite、Vault の cloud sync とは異なる。配置先ごとに R2 または Unity Catalog Volume を使いつつ、公開範囲を Server の identity で管理する必要がある。

## Decision

- `/api/v1/artifacts/{artifact_id}` は最大64 MiBの任意 bytes を保存する。Server は内容の分類、malware scan、HTML sanitization、versioning を行わない。
- metadata は application database、bytes は R2 または Databricks managed Volume に保存する。artifact は作成者の personal workspace が所有し、既定は private、明示的な `PATCH` だけで public にする。削除済み UUID は reservation tombstone で永久に再利用を拒否し、既存 public URL の乗っ取りを防ぐ。指定ユーザー共有、一覧、履歴 API は持たない。
- private read は owner と `api.artifact.read`、mutation は owner と `api.artifact.write` を要求する。他 owner の ID は `404` とする。public read は匿名を許可する。
- R2 read は認可後に300秒の method-specific pre-signed URLへ `307` する。発行済み URL は private 化または削除後も期限まで有効になり得る。Databricks は App service principal で Files API を呼び、Range を含む response を streaming relay する。relay には CSP sandbox を付け、任意 HTML に Dahlia application origin の権限を与えない。
- 公開用の正準 URL は storage URL ではなく Dahlia API URL とする。
- macOS 側から録音、transcript、SQLite、Vault を自動 upload または同期する機能は追加しない。

## Consequences

- 利用者は生成物を明示的に upload／公開できるが、機密性と内容の安全性を公開前に判断する責任を持つ。
- storage credential は client に配布しない。R2 では read-only signing credential、Databricks では App service principal の `WRITE_VOLUME` を deployment が管理する。
- Server または artifact storage の停止は artifact 操作だけを失敗させ、macOS の録音・保存・検索は影響を受けない。

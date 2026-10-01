# 開発 PostgreSQL の旧ジョブテーブル移動手順（廃止）

この文書で扱っていた `app.jobs_*` から `jobs.*` への手動移行は、過去の開発 baseline 用の手順であり、現在の Server には適用しない。

Server は未リリースで、現行 schema は共通キューを含む空 DB 用 baseline に統合した。既存開発 DB の移行は提供しない。必要なデータをバックアップし、新しい空 DB を明示的に指定して [Server README](../README.md#database-and-gateway-configuration) の migration を実行する。既存 DB や適用 ledger を削除・書き換えて再適用しない。

Desktop の公開済み DB はこの扱いの対象外で、データを保持する forward migration を維持する。

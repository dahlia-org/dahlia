# ADR-0062: 統合検索 projection と非同期 Hybrid 検索を追加する

- Status: Accepted
- Date: 2026-09-03
- Amends: ADR-0060
- Builds on: ADR-0059, ADR-0061

## Context

全文検索だけでは語彙が一致しない meeting や screenshot を発見できない。一方、同期 transaction 内で外部 embedding
inference を待つと Desktop の upload と正本保存が外部モデルの可用性に依存する。meeting と screenshot が別々に持つ
全文索引へ vector を追加すると、非同期更新、model 変更、再構築の状態も重複する。

## Decision

- `content.search_documents` を meeting と screenshot に共通する再生成可能な検索 projection とする。Server が生成した
  token 列、embedding 用自然文、content hash を canonical content と同じ transaction で更新する。transcript、翻訳文、
  UUID、summary の内部 metadata は含めない。
- `content.search_embeddings` に現在の model、dimensions、content hash と vector を保存する。`core.search_index_jobs` は
  raw text を持たない lease 付き durable queue とし、Node worker が App service principal で最大16文書を非同期処理する。
  document は instruction なし、query は検索用の固定 instruction 付きで Databricks embedding endpoint へ送る。
- `DAHLIA_SEARCH_EMBEDDING_MODEL` が未指定または空なら embedding を無効にする。dimensions は32から1024の2の冪に限定し、
  既定を1024とする。DAB の検証既定だけ `system.ai.qwen3-embedding-0-6b` を設定する。
- Lakebase は `lakebase_vector` と `lakebase_ann`、その他の PostgreSQL は pgvector の `vector` extension と HNSW を使う。
  model と dimensions を index と query の条件に含める。SQLite Node は Float32 BLOB の exact cosine、D1 は FTS-only とする。
- query がある場合は FTS と vector の上位100件を並行取得し、`k=60` の reciprocal rank fusion で統合する。
  query embedding の失敗、未生成、model 変更中は FTS 結果をそのまま返す。既存 REST、MCP、Web の型と URL は変えない。
- projection と vector table に既存 Vault permission による FORCE RLS を適用する。worker も job の owner user ID で
  identity transaction を開き、保存直前に content hash と owner permission を再確認する。

## Consequences

- canonical content の commit は embedding provider を待たず、vector は削除や model 変更後も再構築できる。
- 同期済み summary、OCR、AI caption と検索 query 原文は設定された embedding provider に送信される。query 原文は
  永続化も log 出力もせず、forwarded user token は使わず、content や credential を queue または log に保存しない。
- Lakebase Search と、embedding 有効時の `lakebase_vector` は operator が利用可能にしておく必要がある。設定済み extension
  または index を作れない場合は migration を停止し、実行時の推論障害だけを FTS へ縮退する。
- Node と Worker は tokenizer と vector capability が異なる。同じ database を runtime 間で移す場合は再同期または
  projection の全再構築が必要になる。
- D1 は vector を持たない FTS-only target とする。ただし現在の D1 adapter は canonical content と projection の複数 statement を
  atomic batch にできないため sync capability を fail-closed とする。D1 sync は `D1Database.batch()` を使う専用 transaction adapter と
  rollback 相当の失敗契約を実装してから有効化する。

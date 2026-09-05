# Server 全文・Hybrid 検索

対象: Server。採択: 2026-09-03。

## 検索 projection

Server は canonical content から自分の検索索引を作る。Desktop の token / ML runtime へ依存せず、`content.search_documents` に meeting と screenshot 共通の再構築可能な projection を持つ。

対象は meeting 名・説明、summary の description / 表示本文、screenshot の OCR / AI caption。transcript、翻訳、UUID、summary 内部 metadata、transcript reference、Project context は含めない。壊れた summary JSON は同期を拒否せず meeting metadata だけを索引する。

Node は固定 Lindera WASM / IPADIC を再利用し、NFKC、原形、stop tag、数値正規化、katakana stem、lowercase を Desktop と揃える。Worker は `Intl.Segmenter` の word token を使う。token、自然文、content hash は canonical content と同じ transaction で更新する。

## 全文検索

PostgreSQL は generated tsvector / GIN、Lakebase は `lakebase_text` / BM25、SQLite / D1 は FTS5 を使う。query は trim 後500文字、最大16 token、全 token の AND。一覧は query なしなら日時順、ありなら関連度・日時・UUID で安定化する。phrase / boolean / prefix 構文、score、内部 token は公開しない。

## Hybrid 検索

`content.search_embeddings` に model / dimensions / content hash / vector を保存する。`core.search_index_jobs` は raw text を持たない lease 付き durable queue。Node worker が owner identity で文書を読み、App service principal により最大16文書ずつ非同期推論する。保存直前に hash と owner permission を再確認する。

- `DAHLIA_SEARCH_EMBEDDING_MODEL` が空なら無効。dimensions は32〜1024の2の冪、既定1024。DAB の検証既定だけ `system.ai.qwen3-embedding-0-6b` を設定する。
- Lakebase は `lakebase_vector` / ANN、他 PostgreSQL は pgvector / HNSW、SQLite Node は Float32 BLOB の exact cosine。model / dimensions を index と query の条件に含める。
- FTS と vector の上位100件を並行取得し RRF（k=60）で統合する。query embedding の失敗、未生成、model 切替中は FTS を返し、REST / MCP / Web の型や URL は変えない。
- 文書は instruction なし、query は固定検索 instruction 付きで設定済み Databricks endpoint へ送る。summary、OCR、caption、query 原文が provider に渡ることを明示し、query を永続化・log しない。forwarded user token は使わない。

## 制限と運用条件

正本 commit は embedding provider を待たない。projection / vector にも Vault permission と FORCE RLS を適用し、同期や検索による認可 bypass を作らない。

Lakebase Search と有効にした vector extension は operator が準備する。必要な extension / index の作成失敗は migration を停止し、実行時の推論障害だけを FTS へ縮退する。初期 corpus の統計更新も運用で行う。

D1 は FTS-only target だが、現在の adapter は canonical content と projection の複数 statement を atomic batch にできないため sync capability 自体を fail-closed とする。専用 `D1Database.batch()` adapter と rollback 相当の失敗契約を実装するまで有効化しない。

Node / Worker は tokenizer と vector capability が異なり、同じ DB の runtime 変更には再同期または projection 全再構築が必要。初期の LIKE 検索と各 canonical row 内の検索列は、再生成境界と非同期 vector 処理を共有する統合 projection に置き換えた。

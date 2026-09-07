# Server 全文・Hybrid 検索

対象: Server。採択: 2026-09-03。

## 検索 projection

Server は canonical content から自分の検索索引を作る。Desktop の token / ML runtime へ依存せず、`app.search_documents` に meeting と screenshot 共通の再構築可能な projection を持つ。

対象は meeting 名・説明、summary の description / 表示本文、screenshot の OCR / AI caption。transcript、翻訳、UUID、summary 内部 metadata、transcript reference、Project context は含めない。壊れた summary JSON は同期を拒否せず meeting metadata だけを索引する。

Node は固定 Lindera WASM / IPADIC を再利用し、NFKC、原形、stop tag、数値正規化、katakana stem、lowercase を Desktop と揃える。Worker は `Intl.Segmenter` の word token を使う。token、自然文、content hash は canonical content と同じ transaction で更新する。

## 全文検索

PostgreSQL は generated tsvector / GIN、Lakebase は `lakebase_text` / BM25、SQLite / D1 は FTS5 を使う。query は trim 後500文字、最大16 token、全 token の AND。一覧は query なしなら日時順、ありなら関連度・日時・UUID で安定化する。phrase / boolean / prefix 構文、score、内部 token は公開しない。

## Hybrid 検索

`app.search_embeddings` に model / dimensions / content hash / vector を保存する。`app.search_index_jobs` は raw text を持たない lease 付き durable queue。Node worker が owner identity で文書を読み、App service principal により最大16文書ずつ非同期推論する。保存直前に hash と owner permission を再確認する。

- `DAHLIA_EMBEDDING_MODEL` が空なら無効。dimensions は32〜1024の2の冪、既定1024。DAB は `${var.catalog}.${var.ai_schema}.embedding` を使い、未登録時に `qwen3-embedding-0-6b` を登録する。
- Lakebase は `lakebase_vector` / ANN、他 PostgreSQL は pgvector / HNSW、SQLite Node は Float32 BLOB の exact cosine。model / dimensions を index と query の条件に含める。
- FTS と vector の上位100件を並行取得し RRF（k=60）で統合する。query embedding の失敗、未生成、model 切替中は FTS を返し、REST / MCP / Web の型や URL は変えない。
- 文書は instruction なし、query は固定検索 instruction 付きで設定済み Databricks endpoint へ送る。summary、OCR、caption、query 原文が provider に渡ることを明示し、query を永続化・log しない。forwarded user token は使わない。

## 制限と運用条件

正本 commit は embedding provider を待たない。projection / vector にも Vault permission と FORCE RLS を適用し、同期や検索による認可 bypass を作らない。

Lakebase Search と有効にした vector extension は operator が準備する。必要な extension / index の作成失敗は migration を停止し、実行時の推論障害だけを FTS へ縮退する。初期 corpus の統計更新も運用で行う。

D1 は FTS-only target だが、現在の adapter は canonical content と projection の複数 statement を atomic batch にできないため sync capability 自体を fail-closed とする。専用 `D1Database.batch()` adapter と rollback 相当の失敗契約を実装するまで有効化しない。

Node / Worker は tokenizer と vector capability が異なり、同じ DB の runtime 変更には再同期または projection 全再構築が必要。初期の LIKE 検索と各 canonical row 内の検索列は、再生成境界と非同期 vector 処理を共有する統合 projection に置き換えた。


## 部分保持クライアント用の全件探索

全件探索は document ID 順に固定する。別Vaultの更新で変化する索引全体の関連度をページ順に使わず、Vault単位のrevisionとcursorで重複・欠落を防ぐ。

`GET /api/v1/vaults/{vaultId}/search?q=...&kind=meeting|screenshot` は既存 FTS projection を直接ページングする。Hybrid の上位100候補制限を使わず、200件以下の ID・meeting ID・180文字以内の snippet と `nextCursor` を返す。cursor は Vault、種類、query、ledger revision、offset を束縛し、途中の canonical 更新は409として新しい探索を要求する。ページごとに現在の identity と Vault 権限を検査する。全件探索完了は nextCursor がない場合だけで、client 側 filter は未探索ページを黙って捨てない。

## Server 画像解析（2026-09-07）

Node は `DAHLIA_CAPTIONING_MODEL` がある場合だけ、アップロードと canonical 登録を終えた会議画像をファイル単位の durable job で解析する。DAB は `${var.catalog}.${var.ai_schema}.gpt-5-6-luna` を使い、captioning alias を作らない。推論は App service principal、入力は既存の1280px WebP variant、出力上限は既存解析と同じ OCR 20,000文字・caption 500文字。画像内の指示は信用しない。OCR は原文、caption は owner のアカウント出力言語。設定未作成時は日本語・全言語とする。

job は5分 lease、失敗分類と指数 backoff、起動時と60秒ごとの不足分探索で復旧する。推論は正本保存と同期を待たせない。既存値は保持し、空 OCR も完了とする。結果確定時は現在の所有権、参照、画像 checksum と revision、lease を再確認し、正本・delta・FTS・embedding job と解析 job の削除を同じ transaction で確定する。共有参照の数だけ推論しない。設定変更による再解析は行わない。

Node は解析 worker を構築した場合だけ capabilities API の `imageAnalysis: true` を返す。Desktop は解析前にこの値を確認して端末解析を省略し、未対応・未設定・旧 Server では端末解析を維持する。端末解析は取得できた Server 言語設定を使い、設定 API が利用できなければ従来の端末値を使う。capability 取得失敗時は job を保持して再試行し、実行中にアカウント接続が変わった結果は保存しない。Server の結果は通常の差分同期で受け取る。Local Account の画像解析と Desktop の会議要約生成は維持する。Workers のジョブ基盤は対象外。

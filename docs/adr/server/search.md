# Server 全文・Hybrid 検索

対象: Server。採択: 2026-09-03。

## 検索 projection

Server は canonical content から自分の検索索引を作る。Desktop の token / ML runtime へ依存せず、`search.documents`（SQLite は `search_documents`） に meeting と screenshot 共通の再構築可能な projection を持つ。

対象は meeting 名・説明、summary の description / 表示本文、screenshot の OCR / AI caption。transcript、翻訳、UUID、summary 内部 metadata、transcript reference、Project context は含めない。壊れた summary JSON は同期を拒否せず meeting metadata だけを索引する。

Node は固定 Lindera WASM / IPADIC を再利用し、NFKC、原形、stop tag、数値正規化、katakana stem、lowercase を Desktop と揃える。Worker は `Intl.Segmenter` の word token を使う。token と content hash は canonical content と同じ transaction で更新する。

## 全文検索

PostgreSQL は generated tsvector / GIN、Lakebase は `lakebase_text` / BM25、SQLite は FTS5 を使う。query は trim 後500文字、最大16 token、全 token の AND。一覧は query なしなら日時順、ありなら関連度・日時・UUID で安定化する。phrase / boolean / prefix 構文、score、内部 token は公開しない。

## Hybrid 検索

検索文書テーブルに nullable な `embedding` と `embedding_model` を統合する。独立した `search_embeddings` と `embedding_text` 列、文書の dimensions 列は持たない。既存の `search_text` を入力とし、その hash は既存の `embedding_content_hash` にのみ保存する。会議名・summary・OCR・caption を含む入力が変わると、同じ transaction で vector と model を NULL にする。検索実行は `jobs.queue` の `kind = search` に統合し、payload に対象 ID・model・dimensions のみを保持する。raw text を queue に移さず、共有 claim の ID・lease・generation・期限を保存時に検証する。Node worker がVault単位の限定された内部読取で文書を読み、App service principal により最大16文書ずつ非同期推論する。保存の UPDATE 条件で最新 hash、claim の generation / model / dimensions、Vault・文書と親の存在を確認する。Meeting / 画像の version は追加しない。モデルとベクトル長が設定に一致する結果だけ検索に使用する。

- `DAHLIA_SEARCH_EMBEDDING_MODEL` が空なら無効。dimensions は32〜1024の2の冪、既定1024。DAB は `system.ai.qwen3-embedding-0-6b` を直接使う。
- Lakebase は `lakebase_vector` / ANN、他 PostgreSQL は pgvector / HNSW、SQLite Node は Float32 BLOB の exact cosine。model / dimensions を index と query の条件に含める。
- FTS と vector の上位100件を並行取得し RRF（k=60）で統合する。query embedding の失敗、未生成、model 切替中は FTS を返し、REST / MCP / Web の型や URL は変えない。
- 文書は instruction なし、query は固定検索 instruction 付きで設定済み Databricks endpoint へ送る。summary、OCR、caption、query 原文が provider に渡ることを明示し、query を永続化・log しない。forwarded user token は使わない。

## 制限と運用条件

正本 commit は embedding provider を待たない。projection / vector にも Vault permission と FORCE RLS を適用し、同期や検索による認可 bypass を作らない。

Lakebase Search と有効にした vector extension は operator が準備する。必要な extension / index の作成失敗は migration を停止し、実行時の推論障害だけを FTS へ縮退する。初期 corpus の統計更新も運用で行う。


Node / Worker は tokenizer と vector capability が異なり、同じ DB の runtime 変更には再同期または projection 全再構築が必要。初期の LIKE 検索と各 canonical row 内の検索列は、再生成境界と非同期 vector 処理を共有する統合 projection に置き換えた。


## Memory と保存チャットの検索 projection（2026-11-03）

Dahlia Memory の保存メモリーと保存チャット（[Dahlia Memory](dahlia-memory.md#検索)）は、会議と同じく正本から再構築できる projection で検索する。表は `search.personal_memory_chunks`、`search.shared_memory_chunks`（正本へ ON DELETE CASCADE）、PostgreSQL 系だけの `agent.session_search_chunks`（`mastra_messages` と `mastra_threads` へ cascade）で、SQLite は memory の 2 表を FTS5 外部 content と trigger で持つ。PostgreSQL の RLS は正本と同じ所有者・Workspace 関数で FORCE する。共有メモリーの再構築は Workspace の search maintenance context で行うため、`app.shared_memories` の read policy にも同じ context を加えた。chunk 本文は projection 内だけの複製で、queue には ID・model・dimensions だけを置く。

- chunk: 段落、改行、文末、UTF-8 の文字境界の順で切り、8,000 bytes 以内、重なりなし。byte と token は同一視しない。
- 同期: 保存メモリーは正本と同じ transaction で chunk を全置換し、内容 hash が変われば embedding を捨てて `memory-index` job を積む。チャットは Mastra が書くため run 終了後に thread 単位の job を積み、job が tokenize と embedding を行う。漏れ、analyzer の変更、model の変更は毎時の reconcile（`memory` は user ごとの個人メモリーとチャット、`workspace-memory` は Workspace ごと）が直す。`memory-index` は `search` group の上限と 429 cooldown を共有する。
- analyzer: 1 つの DB は 1 つの analyzer で索引し、query も同じ analyzer で分解する。行に analyzer ID を保存し、一致しない行は語の検索に使わない（vector は analyzer に依存しないので使い続ける）。Lakebase で `lakebase_tokenizer` が `pg_available_extensions` にあれば migration が `public` に入れ、`public.tokenizer_japanese` で DB 側が tokenize する（ID は `lakebase_tokenizer@<extversion>/tokenizer_japanese`。ALTER EXTENSION UPDATE は保存済み tsvector を作り直さないため版を含める）。無ければ起動を止めず、警告 log `search_japanese_tokenizer_unavailable` を出して Node の Lindera token を `simple` 設定で索引する。会議検索の `lakebase_text` / `lakebase_vector` は従来どおり必須で、読込失敗は migration を止める。素の PostgreSQL と SQLite も Lindera、Workers は `Intl.Segmenter`（全語 AND）を使う。runtime を変えた DB は、新しい runtime の reconcile が全行を自分の analyzer で作り直す。
- 語の検索: query の語は `to_tsvector(<analyzer の設定>, query)` の lexeme（最大 16）を引用符付きの tsquery にしたもので、index 側の lexeme と一致する。PostgreSQL は GIN と `ts_rank_cd`（IDF なし）、Lakebase は BM25 index と `<@> to_bm25query(array_to_tsvector(lexemes), index)`、SQLite は FTS5 の bm25 で並べる。Lakebase は会議検索と同じく BM25 index scan を transaction 内で止め、絞り込んだ全候補を採点する。
- 意味検索: 文書は instruction なし、query は memory 用・chat 用の固定 instruction 付きで、要求ごとに 1 回だけ embedding し全 scope で共有する。model と dimensions が設定と一致する行だけを使い、partial HNSW / `lakebase_ann` を chunk 表ごとに作る。query embedding の失敗・期限（2 秒）・予算超過は語の検索だけに縮退する。
- 文書側の失敗: 429・5xx・timeout は backoff と group cooldown で再試行する。400 / 413 / 422 で batch を拒否されたら 1 件ずつ送り直し、それでも拒否された chunk は最大 2 回半分に分けて（2,000 bytes 未満にはしない）各部分の vector の正規化平均を使う。なお拒否されたら job を failed にし、内容が変わるまで語の検索だけで引ける。

Lakebase の `lakebase_tokenizer` を `public` に入れたときの設定名、日本語設定と `lakebase_bm25` / `to_bm25query` の組み合わせ、`array_to_tsvector` で作った query の BM25 採点は公式例がなく、実環境で未検証である。BM25 の corpus 統計は index 作成時に計算されるため、初回の取り込み後に `VACUUM search.personal_memory_chunks, search.shared_memory_chunks, agent.session_search_chunks;` を実行する。

## 共通検索 API とクライアント切替（2026-09-08）

`POST /api/v1/search` を Desktop Server account・Web・Server MCP `search` の共通検索とする。検索語は `query: string` のみ。必須 `vaultId`、省略時空の query、任意 kind／子孫を含む projectId／タイムゾーン付き from・to／種類ごと既定50・最大100の limit を受け取る。trim後500 UTF-16コード単位、16 KiB body、厳密な型と期間を既存の認証境界で検証する。日付は meeting 作成日時、screenshot 撮影日時の開始以上・終了未満。project は名前・階層パスの NFKC 小文字化した各語を AND 検索し、所属する子孫会議の更新順で返す。日付指定時は該当期間に作成された会議を持つ project に限る。

既存 FTS／vector／RRF を再利用し、全種類で1回の query embedding を共有する。認可・project・日付条件を候補上限の前に適用し、応答直前にも共有権限を再確認する。返すのは種類別の ID、タイトル、所属、日時、snippet、画像参照、件数制限情報。score、vector、全件用 cursor は返さない。`Cache-Control: no-store` とし query を log に残さない。既存一覧の query も同じ検索処理を維持する。

`search: { version: 1 }` capability がある Server の Desktop 主検索はこの順位を保持し、未保持本文を取得せず同期済み metadata に投影する。未同期項目は別枠とし順位へ混ぜない。Local account は従来の FTS。オフライン・旧 Server・metadata 同期待ち・タグ指定・複数 project 指定は端末内検索と明示する。Web は native dialog、300ms debounce、IME 抑制、AbortSignal、Vault 単位の mount、既存 live query を使う。上位100件は全件完了と表現せず、段階表示と絞り込みを提供する。

既存 GET 全件探索と local content broker の契約は以下のとおり維持する。今回 schema／依存／本番 migration／配備変更はない。Lakebase 実環境の BM25／ANN と実 embedding の検証は未実施で、既存設定の検証環境で同一 fixture・query・filter の REST／MCP 結果と embedding 障害時の FTS を比較する必要がある。

## 部分保持クライアント用の全件探索

全件探索は document ID 順に固定する。別Vaultの更新で変化する索引全体の関連度をページ順に使わず、Vault単位のrevisionとcursorで重複・欠落を防ぐ。

`GET /api/v1/vaults/{vaultId}/search?q=...&kind=meeting|screenshot` は既存 FTS projection を直接ページングする。Hybrid の上位100候補制限を使わず、200件以下の ID・meeting ID・180文字以内の snippet と `nextCursor` を返す。cursor は Vault、種類、query、ledger revision、offset を束縛し、途中の canonical 更新は409として新しい探索を要求する。ページごとに現在の identity と Vault 権限を検査する。全件探索完了は nextCursor がない場合だけで、client 側 filter は未探索ページを黙って捨てない。

## Server 画像解析（2026-09-07）

Node は `DAHLIA_IMAGE_ANALYSIS_MODEL` がある場合だけ、アップロードと canonical 登録を終えた会議画像をファイル単位の durable job で解析する。DAB は 2026-09-25 に `system.ai.gpt-5-6-luna` から `system.ai.gpt-6-luna` に変更し、captioning alias を作らない。推論は App service principal、入力は既存の1280px WebP variant、出力上限は既存解析と同じ OCR 20,000文字・caption 500文字。画像内の指示は信用しない。OCR は原文、caption は owner のアカウント出力言語。設定未作成時は日本語・全言語とする。

job は5分 lease、失敗分類と指数 backoff、起動時と60秒ごとの不足分探索で復旧する。推論は正本保存と同期を待たせない。既存値は保持し、空 OCR も完了とする。結果確定時は現在の所有権、参照、画像 checksum と revision、lease を再確認し、正本・delta・FTS・embedding job と解析 job の削除を同じ transaction で確定する。共有参照の数だけ推論しない。設定変更による再解析は行わない。

Node は解析 worker を構築した場合だけ capabilities API の `imageAnalysis: { version: 2 }` を返す。Desktop は解析前にこの値を確認して端末解析を省略し、未対応・未設定・旧 Server では端末解析を維持する。Local→Server 移管では v2 のときだけ初回 file upsert に `imageAnalysis: "replace"` を付け、Server が原本と会議 attachment を確認後に OCR・caption を再生成する。capability 取得失敗時は通常の移管を継続し、強制再生成だけを省略する。端末解析は取得できた Server 言語設定を使い、設定 API が利用できなければ従来の端末値を使う。通常解析の capability 取得失敗時は job を保持して再試行し、実行中にアカウント接続が変わった結果は保存しない。Server の結果は通常の差分同期で受け取る。Local Account の画像解析と Desktop の会議要約生成は維持する。Workers のジョブ基盤は対象外。

2026-09-18: 上記の Desktop fallback 契約を廃止する。Server Workspace の画像解析は Server が常に所有し、Desktop は `imageAnalysis` capability の有無・version・取得成否や Server のモデル設定にかかわらず端末解析を実行しない。Server で解析されない場合も端末へ切り替えず、OCR / caption は未生成のままにする。Desktop は Server の結果を通常の差分同期で受け取り、接続変更時は該当 job だけを再試行する。端末解析は Local Account の画像に限定する。

2026-09-18（再改定）: 直前の fallback 廃止を撤回する。Desktop は capability v2 の Server Workspace だけ画像解析を Server へ委譲し、capability が未対応・未設定・旧 version の場合は従来どおり端末解析する。capability 取得失敗時は job を保持して再試行する。`replace` 待機中は imported OCR / caption の embedding を enqueue せず、解析成功時は生成結果の embedding を一度だけ enqueue する。解析が終端失敗した場合は imported OCR / caption の embedding を共通 search job として復旧する。

## Server Vault 暗号化との境界

暗号化 Vault でも検索データ全体（検索用テキスト、vector、索引）は暗号化対象外とする。PostgreSQL / Lakebase は DB 側の全文検索・vector 検索と既存 RRF、SQLite は既存の exact cosine を使い、暗号化用の復号 scan は行わない。正本の暗号化は維持する。保護範囲は [Vault 暗号化](vault-encryption.md) を参照。

search_index_jobsはVault IDをidentityとして再構築・リトライする。Adminの交代には依存せず、用途と対象Vaultを限定したmaintenance contextでRLSを通す。

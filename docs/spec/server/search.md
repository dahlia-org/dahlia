# Server 全文・Hybrid 検索

対象: Server。採択: 2026-09-03。

## 検索 projection

Server は canonical content から自分の検索索引を作る。Desktop の token / ML runtime へ依存せず、`search.documents`（SQLite は `search_documents`）に meeting と screenshot 共通の再構築可能な projection を持つ。

対象は meeting 名・説明、summary の description / 表示本文、screenshot の OCR / AI caption である。transcript、翻訳、UUID、summary 内部 metadata、transcript reference、Project context は含めない。壊れた summary JSON は同期を拒否せず、meeting metadata だけを索引する。

Lakebase では `lakebase_tokenizer`（0.2.0 以降）の組み込み設定 `public.tokenizer_japanese` で DB が tokenize し（2026-11-05）、Server は本文を分割せずに保存する。parser が捨てる 2,000 bytes 超の連続だけ空白で区切る（下記「parser の token 上限」）。素の PostgreSQL と SQLite の Node は固定の Lindera WASM / IPADIC を使い、NFKC、原形、stop tag、数値正規化、katakana stem、lowercase を Desktop と揃える。Worker は `Intl.Segmenter` の word token を使う。アプリ側の token は PostgreSQL では `simple` 設定、SQLite では FTS5 で索引する。

`search.documents` の tsvector 列は generated 列ではない。sync store が本文と同じ文で DB の設定（Lakebase は `public.tokenizer_japanese`、他は `simple`）の `to_tsvector` を書く。そのため schema と migration は PostgreSQL と Lakebase で共通になる。ALTER EXTENSION UPDATE や runtime の変更より前に保存した行は、次に保存されるまで古い tokenizer の lexeme のまま索引される。本文・token・tsvector と content hash は canonical content と同じ transaction で更新する。

## 全文検索

PostgreSQL は tsvector / GIN、Lakebase は `lakebase_text` / BM25、SQLite は FTS5 を使う。query は trim 後 500 文字、全語の AND とする（アプリ側で分割するときは最大 16 token。Lakebase は `plainto_tsquery(tokenizer_japanese)`）。一覧は query なしなら日時順、ありなら関連度・日時・UUID で安定化する。phrase / boolean / prefix 構文、score、内部 token は公開しない。

## Hybrid 検索

検索文書テーブルに nullable な `embedding` と `embedding_model` を統合する。独立した検索 embedding table と `embedding_text` 列、文書の dimensions 列は持たない。入力は既存の `search_text` とし、その hash は既存の `embedding_content_hash` にのみ保存する。会議名・summary・OCR・caption を含む入力が変わると、同じ transaction で vector と model を NULL にする。

検索の実行は `jobs.queue` の `kind = search` に統合する。payload には対象 ID・model・dimensions だけを保持し、raw text は queue に置かない。Node worker は Workspace 単位の限定された内部読取で文書を読み、App service principal により最大 16 文書ずつ非同期に推論する。保存の UPDATE 条件では、最新 hash、claim の generation / model / dimensions、Workspace・文書と親の存在を確認する。共有 claim の ID・lease・generation・期限は保存時に検証する。Meeting / 画像の version は追加しない。モデルとベクトル長が設定に一致する結果だけを検索に使う。

- `DAHLIA_SEARCH_EMBEDDING_MODEL` が空なら無効とする。dimensions は 32〜1024 の 2 の冪で、既定は 1024 である。DAB は `system.ai.qwen3-embedding-0-6b` を直接使う。
- Lakebase は `lakebase_vector` / ANN、他の PostgreSQL は pgvector / HNSW、SQLite Node は Float32 BLOB の exact cosine を使う。model / dimensions を index と query の条件に含める。
- FTS と vector の上位 100 件を並行取得し、RRF（k=60）で統合する。query embedding の失敗、未生成、model 切替中は FTS を返す。REST / MCP / Web の型や URL は変えない。
- 文書は instruction なし、query は固定の検索 instruction 付きで、設定済みの Databricks endpoint へ送る。summary、OCR、caption、query 原文が provider に渡ることを明示する。query は永続化・log しない。forwarded user token は使わない。

## 制限と運用条件

正本 commit は embedding provider を待たない。projection / vector にも Workspace permission と FORCE RLS を適用し、同期や検索による認可 bypass を作らない。

Lakebase Search と、有効にした vector extension は operator が準備する。必要な extension / index の作成が失敗した場合は migration を停止する。実行時の推論障害だけを FTS へ縮退する。初期 corpus の統計更新も運用で行う。

Node と Worker は tokenizer と vector capability が異なる。同じ DB の runtime を変えるには、再同期または projection の全再構築が必要である。

## Memory と保存チャットの検索 projection（2026-11-03）

Dahlia Memory の保存メモリーと保存チャット（[Dahlia Memory](dahlia-memory.md#検索)）は、会議と同じく正本から再構築できる projection で検索する。表は `search.personal_memory_chunks`、`search.shared_memory_chunks`（正本へ ON DELETE CASCADE）、PostgreSQL 系だけの `agent.session_search_chunks`（`mastra_messages` と `mastra_threads` へ cascade）である。SQLite は memory の 2 表を FTS5 外部 content と trigger で持つ。PostgreSQL の RLS は正本と同じ所有者・Workspace 関数で FORCE する。共有メモリーの再構築は Workspace の search maintenance context で行うため、`app.shared_memories` の read policy にも同じ context を加える。chunk 本文は projection 内だけの複製であり、queue には ID・model・dimensions だけを置く。

- chunk: 段落、改行、文末、UTF-8 の文字境界の順で切り、8,000 bytes 以内、重なりなし。byte と token は同一視しない。
- 同期: 保存メモリーは正本と同じ transaction で chunk を（記録, chunk 番号）ごとに書き直し、余った chunk を消す。本文が変わらない chunk は embedding を残し、変わった chunk の embedding だけを捨てる。本文の hash が変わったときに `memory-index` job を積む。chunk は作成元の正本 revision を持ち、analyzer と revision が正本と一致する chunk だけを最新として扱う。reconcile の書き直しは保存と同じ mutation lock を取ってから正本を読み直すため、並行する保存を古い本文で上書きしない。チャットは Mastra が書くため、run 終了後に thread 単位の job を積み、job が tokenize と embedding を行う。漏れ、analyzer の変更、model の変更は毎時の reconcile（`memory` は user ごとの個人メモリーとチャット、`workspace-memory` は Workspace ごと）が直す。`memory-index` は `search` group の上限と 429 cooldown を共有する。
- analyzer: 1 つの DB は 1 つの analyzer で索引し、query も同じ analyzer で分解する。行に analyzer ID を保存し、一致しない行は語の検索に使わない（vector は analyzer に依存しないので使い続ける）。Lakebase では `lakebase_tokenizer` が `lakebase_text` と同じく必須で、migration が `public` に入れる。入れられない（別の schema に入っている場合を含む）ときは migration を止める。`public.tokenizer_japanese` で DB 側が tokenize する。ID は `lakebase_tokenizer@<extversion>/tokenizer_japanese/runs2000` とする。ALTER EXTENSION UPDATE は保存済みの tsvector を作り直さないため、版を含める。版は process ごとに初回だけ読むので、更新後は App を再起動する。素の PostgreSQL と SQLite は Lindera、Workers は `Intl.Segmenter` を使う（全語 AND。1 件も一致しないときは、どれかの語の一致に緩める）。runtime を変えた DB は、新しい runtime の reconcile が全行を自分の analyzer で作り直す。
- parser の token 上限: PostgreSQL の parser は 2,047 bytes（Lakebase は 2,046 bytes、区切りのない CJK 682 字相当）を超える token を辞書に渡す前に捨てる。DB 側で tokenize する analyzer（会議検索を含む）では、文書と query の両方で、空白・句読点・記号を含まない 2,000 bytes 超の連続に空白を挟んでから `to_tsvector` に渡す。区切りは窓の後半で最後に文字種（漢字・ひらがな・カタカナ・その他）が変わる位置を選び、無ければ文字の境界で切る。文字種が変わらない長い連続では、語の途中で切れることがある。
- 語の検索: query の語は `to_tsvector(<analyzer の設定>, query)` の lexeme（最大 16）を引用符付きの tsquery にしたもので、index 側の lexeme と一致する。PostgreSQL は GIN と `ts_rank_cd`（IDF なし）、Lakebase は BM25 index と `<@> to_bm25query(array_to_tsvector(lexemes), index)`、SQLite は FTS5 の bm25 で並べる。Lakebase は会議検索と同じく BM25 index scan を transaction 内で止め、絞り込んだ全候補を採点する。
- 意味検索: 文書は instruction なし、query は memory 用・chat 用の固定 instruction 付きで、要求ごとに 1 回だけ embedding し、全 scope で共有する。model と dimensions が設定と一致する行だけを使い、partial HNSW / `lakebase_ann` を chunk 表ごとに作る。query embedding の失敗・期限（2 秒）・予算超過は語の検索だけに縮退する。
- 文書側の失敗: 429・5xx・timeout は backoff と group cooldown で再試行する。400 / 413 / 422 で batch を拒否されたら、1 件ずつ送り直す。それでも拒否された chunk は最大 2 回、半分の大きさを目安に分け（目安が 2,000 bytes 未満になるなら分けない）、各部分の vector の正規化平均（長さによらず等しい重み）を使う。分割は chunk と同じく段落・改行・文末を優先するため、個々の部分は目安より小さくなることがある。拒否された chunk は vector なしの処理済みとして記録し、内容が変わるまで語の検索だけで引ける。429・5xx・timeout は回数の上限なく再試行し、reconcile は待機中・実行中の job がない記録を毎時積み直す。

BM25 の corpus 統計は index 作成時に計算されるため、初回の取り込み後に `VACUUM search.personal_memory_chunks, search.shared_memory_chunks, agent.session_search_chunks;` を実行する。

## 共通検索 API とクライアント切替（2026-09-08）

`POST /api/v1/search` は Desktop の Server account、Web、Server MCP `search` の共通検索である。検索語は `query: string` のみとする。必須の `vaultId`、省略時の空の query、任意の kind と子孫を含む projectId、タイムゾーン付きの from・to、種類ごとの既定 50・最大 100 の limit を受け取る。trim 後 500 UTF-16 コード単位、16 KiB body、厳密な型と期間を既存の認証境界で検証する。日付は meeting の作成日時、screenshot の撮影日時について、開始以上・終了未満で判定する。project は名前・階層パスの NFKC 小文字化した各語を AND で検索し、所属する子孫会議の更新順で返す。日付指定時は、該当期間に作成された会議を持つ project に限る。

既存の FTS / vector / RRF を再利用し、全種類で 1 回の query embedding を共有する。認可・project・日付条件は候補上限の前に適用し、応答直前にも共有権限を再確認する。返すのは種類別の ID、タイトル、所属、日時、snippet、画像参照、件数制限情報である。score、vector、全件用 cursor は返さない。`Cache-Control: no-store` とし、query を log に残さない。既存一覧の query も同じ検索処理を使う。

`search: { version: 1 }` capability を持つ Server の Desktop 主検索は、この順位を保持する。未保持の本文は取得せず、同期済み metadata に投影する。未同期項目は別枠とし、順位に混ぜない。Local Account は従来の FTS を使う。オフライン・旧 Server・metadata 同期待ち・タグ指定・複数 project 指定は端末内検索と明示する。Web は native dialog、300ms debounce、IME 抑制、AbortSignal、Workspace 単位の mount、既存の live query を使う。上位 100 件は全件完了と表現せず、段階表示と絞り込みを提供する。

## 部分保持クライアント用の全件探索

全件探索は document ID 順に固定する。別 Workspace の更新で変化する索引全体の関連度をページ順に使わず、Workspace 単位の revision と cursor で重複・欠落を防ぐ。

`GET /api/v1/vaults/{vaultId}/search?q=...&kind=meeting|screenshot` は既存 FTS projection を直接ページングする。Hybrid の上位 100 候補制限は使わない。200 件以下の ID・meeting ID・180 文字以内の snippet と `nextCursor` を返す。cursor は Workspace、種類、query、ledger revision、offset を束縛する。途中の canonical 更新は `409` とし、新しい探索を要求する。ページごとに現在の identity と Workspace 権限を検査する。全件探索の完了は `nextCursor` がない場合だけである。client 側の filter は未探索ページを黙って捨てない。

## 画像解析と受理済みジョブ

Desktop で作成した画像の解析・設定所有・同期時の扱いは [アカウント別 Desktop 推論](../shared/account-scoped-desktop-inference.md) に従う。同期や不足データの巡回だけでは Server の画像解析を新規登録しない。

Node の Server 画像解析 worker は受理済みのジョブだけを復旧する。推論は App service principal で行い、入力は既存の 1280px WebP variant、出力上限は OCR 20,000 文字・caption 500 文字とする。画像内の指示は信用しない。OCR は原文、caption はジョブの出力言語とする。

受理済み job は 5 分の lease、失敗分類と指数 backoff を持つ。推論は正本保存と同期を待たせず、既存値を保持し、空の OCR も完了とする。結果確定時は、現在の所有権、参照、画像の checksum と revision、lease を再確認する。正本・delta・FTS・embedding job と解析 job の削除を同じ transaction で確定する。共有参照の数だけ推論せず、設定変更による再解析は行わない。

受理済みの `replace` の待機中は imported OCR / caption の embedding を enqueue しない。解析成功時は生成結果の embedding を一度だけ enqueue し、終端失敗時は imported OCR / caption の embedding job を共通 search worker へ復旧する。

## Server Workspace 暗号化との境界

暗号化 Workspace でも検索データ全体（検索用テキスト、vector、索引）は暗号化対象外とする。PostgreSQL / Lakebase は DB 側の全文検索・vector 検索と既存の RRF、SQLite は既存の exact cosine を使う。暗号化用の復号 scan は行わない。正本の暗号化は維持する。保護範囲は [Workspace 暗号化](vault-encryption.md) を参照する。

検索の再構築と再試行は Workspace ID を identity とし、`jobs.queue` の `kind = search` で行う。Admin の交代には依存せず、用途と対象 Workspace を限定した maintenance context で RLS を通す。

## 未適合・未検証

- 未検証: Lakebase の `lakebase_tokenizer` を `public` に入れたときの設定名、日本語設定と `lakebase_bm25` / `to_bm25query` の組み合わせ、`search.documents` の会議検索での `plainto_tsquery(tokenizer_japanese)`、`array_to_tsvector` で作った query の BM25 採点、挿入した空白で Lakebase の parser が token を区切ること。公式例はなく、実環境で確認していない。token 上限の回避は PostgreSQL の同じ parser 上限で確かめた。
- 未検証: Lakebase 実環境の BM25 / ANN と実 embedding の検証は未実施である。既存設定の検証環境で、同一の fixture・query・filter に対する REST / MCP の結果と、embedding 障害時の FTS を比較する必要がある。

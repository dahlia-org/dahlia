# ADR-0060: 同期済み meeting に Server 全文検索を追加する

- Status: Accepted
- Date: 2026-09-03
- Amends: ADR-0056
- Builds on: ADR-0033, ADR-0034, ADR-0038, ADR-0059

## Context

同期済み meeting と screenshot の Private Web／Server MCP は `LIKE` 検索しか持たず、日本語の活用形や複数語を扱えない。
Desktop の検索索引はローカル SQLite の projection であり、Server がその runtime や token 列へ依存すると、同期契約と再構築境界が崩れる。

## Decision

- Server が同期 manifest の受理時に検索対象を token 化する。meeting は名前、説明、正準 summary の description と表示本文、
  screenshot は OCR と AI caption を対象とする。transcript、summary metadata、UUID、transcript reference は索引しない。
- Node は固定 dependency `lindera-wasm-ipadic-nodejs` 2.3.4 と IPADIC を process 内で再利用し、Desktop analyzer と同じ
  NFKC、base form、stop tag、number normalization、katakana stem、lowercase 規則を適用する。Cloudflare Worker は
  Node 専用 WASM を bundle せず、`Intl.Segmenter` の word token を使用する。
- token 化済みの空白区切り文字列を canonical row の内部 `search_text` として同じ transaction で保存する。
  PostgreSQL は generated `tsvector` と GIN、Lakebase は `lakebase_text` の `lakebase_bm25`、SQLite／D1 は
  external-content FTS5 と trigger を使う。検索 query でも既存の Vault permission／RLS を必須とする。
- query は trim 後500文字、最大16 token とし、全 token の AND 一致にする。phrase、boolean、prefix 構文、score、token、
  `search_text` は公開しない。query が無い場合は従来の日時順、query がある場合は関連度、従来の日時順、UUID順で安定化する。
- Lakebase deployment は operator が事前に Lakebase Search を有効化する。migration は `lakebase_text` extension と BM25 indexを
  必須化し、利用できなければ起動を停止する。初回全同期後は corpus 統計更新のため両 content table を `VACUUM` する。

## Consequences

- REST と MCP の既存 `q`／`query` contract と response typeを変えず、日本語を含む全文検索を提供できる。
- Node と Worker の tokenizer および rank 実装は完全一致しない。同じ DB を別 runtimeへ切り替える場合は DB再作成または
  全 meeting 再同期が必要になる。
- malformed summary JSON は同期を拒否せず、meeting名と説明だけを索引する。
- transcript検索、semantic/vector検索、highlight/snippet、検索telemetryは追加しない。

# ADR-0033: ローカル検索に再構築可能な FTS5 projection を使う

- Status: Accepted
- Date: 2026-08-16
- Builds on: ADR-0006, ADR-0007, ADR-0009
- Amended by: ADR-0034

## Context

ミーティングとプロジェクトの暫定検索は、取得した metadata に対する部分文字列一致で、日本語の活用・表記正規化に対応しない。検索索引は正本ではないため、破損時に全件再生成できる必要がある。将来は transcript 検索と 256 次元 embedding の vector 索引を追加する。

## Decision

- `search_documents` を meeting metadata、summary 本文、project の共通 registry とし、contentless `search_documents_fts` を projection として持つ。summary metadata と原文・翻訳文とも transcript は索引しない。将来の vector projection は `search_documents_vec` とする。
- job と index state は `indexKind` を持ち、今回は `fts` 行だけを使う。将来の `vector` は同じ registry と queue contract を共有し、独立した generation、revision、進捗を持つ。
- FTS5 tokenizer は Lindera 2.0.1 と埋め込み IPADIC を使う arm64 static XCFramework とする。YAML 設定は Rust バイナリへ埋め込み、version と hash を DB に永続化する。release panic は unwind とし、全 C ABI を panic boundary で保護する。
- source table の trigger は `search_index_jobs` の upsert だけを行う。calendar/tag 更新は参照する meeting、project の階層更新は変更 subtree だけを enqueue・再索引する。transcript 更新は job を生成しない。形態素解析と FTS 更新は utility-priority の `SearchIndexer` actor が非同期に処理し、録音中は停止する。cleanup job は analyzer failure 中も処理する。
- 通常更新は source hash が同じ FTS 行の再処理を省略する。明示的な再構築と乖離修復は source hash にかかわらず全行を再トークナイズする。
- v35 適用後は meeting metadata と project を backfill する。初期構築・再構築中は検索 unavailable とし、旧 metadata 部分一致へはフォールバックしない。
- query は2文字以上、最大16 token とし、最後の token だけ prefix にする。各 token は独立に検索し、meeting metadata の異なる field に分散していても全 token が揃えば一致とする。phrase や隣接性は要求しないが、BM25 の語頻度を保持するため FTS は `detail=full` とする。
- MCP の `query_meetings` も既定で同じ FTS projection を使う。`simple: true` の場合だけ、metadata と summary 本文に対する literal substring (`LIKE`) 検索を使う。
- `fts5vocab` の文書頻度が最小の token から候補 meeting を作り、残りの token と evidence ranking は候補文書内で評価する。token 集合を交差させてから pagination し、候補数によって全 token 一致を取りこぼさない。SQLite read は 30 秒でキャンセルし、時間内に完了しない広い query には絞り込みを求める。
- 順位は title、tag/path/calendar、description/summary の証拠クラスを優先し、全 token のうち最も弱い証拠と BM25 を使う。hit 数は加算しない。cursor は FTS revision と offset を持つ。source job の enqueue と projection の各変更で revision を同じ transaction 内に進め、revision が変われば active query と pagination を先頭から置換する。
- FTS secure-delete と一時的な SQLite `secure_delete=ON` を索引削除に使う。
- Settings の検索カテゴリで phase、進捗、pending/processing job、error を表示し、全件再構築を要求できるようにする。
- 同じ job が5回失敗した場合は queue から除去して index を failed にし、無制限 retry を行わない。

## Consequences

- 既定の FTS とアプリ検索は、日本語の原形化、NFKC、数値正規化、カタカナ stem を含む metadata・summary 本文の token 検索を提供する。一文字・語中部分一致は simple 検索だけで利用でき、transcript 検索は提供しない。
- contentless FTS は token index だけを保持するため、`search_documents_fts` の列を直接 SELECT すると `NULL` を返す。索引状況は registry との rowid 対応、`MATCH`、`search_documents_fts_vocab` で確認する。
- projection の遅延中や初期構築中は結果が一時的に欠ける。検索 failure は録音・確定文字起こしの保存へ波及しない。
- 高頻度 token の検索は結果を推測で打ち切らず、期限を超えた場合は明示的な絞り込みエラーになる。
- arm64 配布物は IPADIC により約20 MB増える。Rust 1.97.0、Cargo.lock、SHA-256 を固定した IPADIC source archive、ビルドスクリプト、Lindera/IPADIC と Rust 推移依存の license を配布工程で管理する。
- FTS5 secure-delete を使用した DB は SQLite 3.42 未満と互換でなく、contentless-delete のため migration は SQLite 3.43 以上を要求する。

## References

- [ADR-0006](0006-bounded-transcript-projection.md)
- [ADR-0007](0007-version-and-restore-sqlite-backups.md)
- [ADR-0009](0009-execution-context-and-degradation-order.md)
- [ADR-0034](0034-index-summary-body-in-local-search.md)

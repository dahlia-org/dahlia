# ADR-0033: ローカル検索に再構築可能な FTS5 projection を使う

- Status: Accepted
- Date: 2026-08-16
- Builds on: ADR-0006, ADR-0007, ADR-0009

## Context

ミーティングとプロジェクトの暫定検索は、取得した metadata に対する部分文字列一致だった。文字起こしから meeting を探せず、日本語の活用・表記正規化にも対応しない。検索索引は録音・文字起こしの正本ではないため、確定文字起こしの durable ingress を待たせず、破損時に全件再生成できる必要がある。将来は 256 次元 embedding の vector 索引を同じ文書 registry と更新キューへ追加する。

## Decision

- `search_documents` を meeting metadata、project、confirmed transcript segment の共通 registry とし、全文を重複保存しない contentless `search_documents_fts` を projection として持つ。transcript は原文だけを検索用 source とし、翻訳文は FTS と将来の vector projection の対象にしない。将来の vector projection は `search_documents_vec` とする。
- job と index state は `indexKind` を持ち、今回は `fts` 行だけを使う。将来の `vector` は同じ registry と queue contract を共有し、独立した generation、revision、進捗を持つ。
- FTS5 tokenizer は Lindera 2.0.1 と埋め込み IPADIC を使う arm64 static XCFramework とする。YAML 設定は Rust バイナリへ埋め込み、version と hash を DB に永続化する。release panic は unwind とし、全 C ABI を panic boundary で保護する。
- source table の trigger は `search_index_jobs` の upsert だけを行う。通常の文字起こし更新は Segment 単位、calendar/tag 更新は参照する meeting、project の階層更新は変更 subtree だけを enqueue・再索引し、backfill と手動再構築だけを cursor 駆動の全件処理にする。形態素解析と FTS 更新は utility-priority の `SearchIndexer` actor が非同期に処理する。cleanup job は analyzer failure 中も処理する。
- 通常更新は source hash が同じ FTS 行の再処理を省略する。明示的な再構築と乖離修復は source hash にかかわらず全行を再トークナイズする。
- v35 適用後は metadata、次に confirmed segment を cursor/range 相当の小さい transaction で backfill する。初期構築中は完成済みの部分結果だけを返し、旧 metadata 部分一致へはフォールバックしない。
- query は2文字以上、最大16 token とし、最後の token だけ prefix にする。各 token は独立に検索し、同じ meeting の metadata と異なる transcript segment に分散していても、全 token が揃えば一致とする。phrase や隣接性は要求しないため FTS は `detail=column` とする。
- `fts5vocab` の文書頻度が最小の token から候補 meeting を作り、残りの token と evidence ranking は候補文書内で評価する。token 集合を交差させてから pagination し、候補数によって全 token 一致を取りこぼさない。SQLite read は 500 ms でキャンセルし、時間内に完了しない広い query には絞り込みを求める。
- 順位は title、tag/path/calendar、description、transcript の証拠クラスを優先し、全 token のうち最も弱い証拠と BM25 を使う。hit 数は加算しない。cursor は FTS revision と offset を持つ。source job の enqueue と projection の各変更で revision を同じ transaction 内に進め、revision が変われば active query と pagination を先頭から置換する。
- FTS secure-delete と一時的な SQLite `secure_delete=ON` を索引削除に使う。meeting delete job は cascade trigger に依存せず、配下 segment 文書を明示的に消す。
- Settings の検索カテゴリで phase、進捗、pending/processing job、error を表示し、全件再構築を要求できるようにする。

## Consequences

- 日本語の原形化、NFKC、数値正規化、カタカナ stem を含む token 検索と transcript evidence の時刻を提供できる。一文字・語中部分一致は提供しない。
- projection の遅延中や初期構築中は結果が一時的に欠ける。検索 failure は録音・確定文字起こしの保存へ波及しない。
- 高頻度 token の検索は結果を推測で打ち切らず、期限を超えた場合は明示的な絞り込みエラーになる。
- arm64 配布物は IPADIC により約20 MB増える。Rust 1.97.0、Cargo.lock、SHA-256 を固定した IPADIC source archive、ビルドスクリプト、Lindera/IPADIC と Rust 推移依存の license を配布工程で管理する。
- FTS5 secure-delete を使用した DB は SQLite 3.42 未満と互換でなく、contentless-delete のため migration は SQLite 3.43 以上を要求する。

## References

- [ADR-0006](0006-bounded-transcript-projection.md)
- [ADR-0007](0007-version-and-restore-sqlite-backups.md)
- [ADR-0009](0009-execution-context-and-degradation-order.md)

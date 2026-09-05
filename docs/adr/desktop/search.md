# ローカル全文検索と旧 Hybrid 検索

対象: Desktop・local MCP。採択: 2026-08。現在の実行・負荷境界は [Architecture](../../../ARCHITECTURE.md#ui-and-interaction-responsiveness)。

## 2026-09: Desktop 検索を全文検索に統一

Simple と Gemma による Neural を廃止し、旧 Advanced の全文検索を唯一の Desktop 検索にする。モード選択、モデル取得・設定、MLX 推論・同梱、vector worker を撤去する。検索対象、ランキング、条件、ページング、索引未準備時の unavailable は維持する。Server と local MCP の検索 API は変更しない。

旧 migration は保持し、追加 migration で vector を無効化して専用 trigger を削除する。DB schema、既存 vector・job は保持するが実行しない。取得済みモデルは現在のアプリプロファイルの `Models/EmbeddingGemma` に限って起動時にバックグラウンド削除する。削除失敗は起動・検索を妨げず次回起動で再試行する。

## 対象と正本

`search_documents` を meeting / Project / screenshot の共通 registry とし、contentless FTS を再構築可能な projection にする。source table trigger は coalesced job を積むだけで、utility worker が解析・索引する。録音中は FTS と画像解析 worker を停止する。検索失敗は確定データ保存を待たせない。

meeting 自由文検索は title、tags、calendar、description、summary の5 field。summary は section heading / block 本文を平坦化し、document title / description / tags / action items、JSON key、UUID、画像 ID、transcript reference を本文 field に混ぜない。壊れた document は空本文にして metadata 検索を維持する。transcript 原文・翻訳文は索引しない。

Project は専用結果と明示 filter で探す。Project name / path を meeting の全文検索から除外し、Project vector による meeting 順位補正もしない。要約生成に既に使った Project 文脈を独立の証拠として二重評価しないためである。Project 専用文書・FTS column と既存 vector は保持できる。

## FTS と順位

固定 Lindera / IPADIC の arm64 XCFramework を使い、NFKC、原形、数値、katakana stem を正規化する。Rust panic は C ABI で隔離し、version / hash / license / Cargo.lock を配布時に管理する。

query は2文字以上、最大16 token、最後だけ prefix。field を跨いでも全 token が揃えば一致とし、最も document frequency の小さい token から候補を作り、残りを交差させてから pagination する。候補を推測で打ち切らず、SQLite read の30秒期限を超えれば絞り込みを求める。

重み付き BM25 を単一スコアとし、同点は日時降順・ID。各 field の重みは0〜10、0は一致対象からも除外、全0 / 不正設定は既定に戻す。seed と残り token にも同じ filter を使う。match field は表示ページだけで判定する。調整は query 時なので再索引不要。

重みは UserDefaults の policy を呼出引数で渡し、開発者設定に preset / slider を置く。preset は重みから導出する。MCP は既定重みだけを使い app 設定を読まないため、app と順位が異なり得る。旧 Simple は比較用 metadata LIKE として一文字・語中一致に対応していたが、2026-09 に廃止した。

## 旧 Neural 検索（2026-09 廃止）

明示 opt-in、既定 OFF。Gemma 規約同意後に pinned model revision / SHA-256 を検証して取得し、MLX EmbeddingGemma の768次元先頭256次元を L2 再正規化する。model / prompt / token budget / 文書構成を configuration hash で管理する。

meeting vector は title + 有効 SummaryDocument の description / section body。summary の実内容が1文字でもあれば対象とし、固定最小文字数を設けない。title / meeting description / tag / calendar / Project だけでは作らない。Project vector は専用文書の path / description を使い、meeting 検索に流用しない。

- 最大4文書・padding 込み4096 tokenの直列 batch とし、成功分を batch transaction で保存する。
- filter 後、cosine 0.45未満を除外して vector 上位100件と FTS 上位100件を RRF（k=60）で統合。同点は FTS候補、FTS順位、vector順位、UUID の順。
- FTS を先に表示し、同じ query の vector 完了時だけ置換する。未導入・失敗・configuration 不一致は FTS を維持する。semantic-only は本文・類似度条件を満たす vector-only 結果だけ。
- OFF 中は新規 vector job / Neural UI を出さない。ON だけでは構築せず、明示再構築で queue を作る。OFF は既存 vector / job を削除せず、対象変更時は再構築待ちに戻す。
- meeting 内容と embedding はローカル推論経路から外へ送らない。MCP は MLX をリンクせず FTS のまま。

1 embedding は1024 bytes、filter 後の線形 scan。5万文書で p95 200ms超が実測された場合に限り vector 拡張を検討する。cosine 閾値は当時の pinned model / 日本語30 query評価に基づき、一般的な品質保証ではない。

## Screenshot 検索

全保存画像を Codex `gpt-5.6-luna` / low で解析し、OCR と caption を正本保存する。モデル fallback はしない。既存 FTS queue の screenshotAnalysis job を最大8並行で処理し、正本と索引を更新する。未設定・未認証・モデル利用不可は試行回数を消費せず待機する。

screenshot は独立結果と `query_screenshots` で返し、meeting に集約せず vector を作らない。caption は解釈なので BM25 重み0.4で OCR より下げる。要約には抽出 text ではなく画像を渡し続ける。アプリ言語を認識候補、要約言語を caption に使い、変更は将来解析分へだけ反映する。画像解析には Codex 経路を使い、全画像分の AI 処理量と DB 容量が増える。

## 再構築と経緯

通常は source hash 一致で再処理を省略し、明示 rebuild / repair は全行を再解析する。cleanup は analyzer failure 中も続ける。job 5回失敗で index failed とし無限 retry しない。画像固有 failure は meeting / Project FTS を failed にしない。

enqueue と projection 更新で revision を同 transaction で進め、query cursor を無効化する。初期 / 全再構築中は unavailable とし、勝手に LIKE へ縮退しない。正本は保持し、snippet は正本から再生成する。contentless column の直接 SELECT は本文取得ではない。FTS secure-delete と索引削除時の SQLite secure_delete を使い、contentless-delete に SQLite 3.43以上を要求する。

固定 evidence class、80文字の vector 足切り、Project による meeting 補正は廃止した。Project を除いた benchmark は旧正解データを再利用せず別 key で生成する。保存済み projectPath 重みは無視し、残りを保つ。schema / model / 索引条件の変更は意味を変えずに履歴へ残す。

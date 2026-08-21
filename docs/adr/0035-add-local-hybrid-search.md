# ADR-0035: 256次元 EmbeddingGemma でローカルハイブリッド検索を提供する

## Status

Accepted

## Decision

- `Neural` は既存 FTS と `mlx-community/embeddinggemma-300m-4bit` の vector 検索を RRF (`k = 60`) で統合する。`Advanced` は FTS、`Simple` は `LIKE` のまま維持する。
- Apple 公式 `mlx-swift-lm` の `MLXEmbedders.EmbeddingGemma` を使い、768次元出力の先頭256次元を取得して L2 再正規化する。モデル revision、prompt、token 上限、文書構成は configuration hash でリリース管理する。
- vector worker は最大4文書かつ padding 込み4096 tokenまでを1バッチとして直列に推論し、成功した結果をバッチ単位のトランザクションで保存する。
- meeting は description と summary 本文の空白を除く合計が80文字以上の場合だけ vector 化する。title、calendar、tag、project path は条件通過後の補助情報に限り、project の文書構成は維持する。文書構成の configuration hash が一致しない索引は ready とせず、明示的な再構築まで FTS に縮退する。
- vector 候補は filter 適用後に cosine 0.45 未満を除外してから上位100件へ絞る。この値は pinned model の日本語30 query judgment setで、no-threshold比の誤検出減、nDCG@10非悪化、semantic Recall@10 90%以上を満たす候補から macro F1、precision、低い閾値の順で選定した。
- RRF 同点時は FTS 候補、FTS 順位、vector 順位、UUID の順で決定し、semantic-only 表示は本文条件と類似度条件を通過した vector-only 結果に限る。
- モデルは Gemma 規約への同意後だけ取得し、固定 revision と SHA-256 を検証する。会議データと embedding はネットワークへ送信しない。
- `search_documents_vec` は正本ではない。FTS projection の source hash 変更を coalesce した独立 job で追随し、録音中は worker を停止する。
- Neural は FTS 結果を先に表示し、同じ query の vector 計算が完了した場合だけ置換する。vector が利用不能なら FTS を維持する。
- ベクトル検索は明示的な opt-in として既定 OFF にする。OFF 中は vector job を作らず、設定のモデル操作と検索モードの Neural を表示しない。有効化だけでは索引を作成せず、全件のキュー追加は再構築操作でのみ行う。無効化では既存の vector と job を削除せず、OFF 中に索引対象が変化した場合は再構築待ちへ戻す。
- MCP の検索契約は変更せず、MCP target は MLX をリンクしない。

## Consequences

1件の embedding は1024 bytesで、検索時は vault と filter 適用後の対象を線形 scan する。5万文書で p95 200 ms を超えることが計測された場合に限り、SQLite vector 拡張を別の判断として検討する。

# ADR-0038: screenshot のテキストと説明を独立したローカル検索結果として索引する

## Status

Accepted; amends ADR-0005, ADR-0033, and ADR-0035.

## Decision

- 保存された全 screenshot は Codex app-server の `gpt-5.6-luna`、reasoning effort `low` で解析し、検出文字を `screenshots.ocrText`、画像説明を `screenshots.caption` に保存する。代替モデルにはフォールバックしない。
- screenshot 作成 trigger は既存の FTS queue に `screenshotAnalysis` job を積むだけとし、FTS worker が最大4枚を一度に解析して、正本保存、`search_documents`、`search_documents_fts` 更新を一続きで行う。独立した画像解析 worker は作らない。
- Codex の未設定、未認証、指定モデル利用不可は一時的な prerequisite 不足として job の試行回数を消費せず queue に残し、自動再試行する。
- 録音中は画像解析を含む FTS worker と vector worker をすべて停止し、終了後に queue から再開する。
- screenshot は `search_documents.kind = 'screenshot'` として索引するが vector は生成しない。検索結果は meeting に集約せず、同じ検索画面と `query_screenshots` MCP tool の独立した screenshot 一覧として返す。
- v38 migration は meeting/project の document ID と既存 vector を保持し、FTS だけを再構築する。
- 要約生成には抽出結果ではなく画像を渡し続ける。ユーザーは画像 overlay で検出文字、画像説明、処理状態を確認でき、MCP では完了済みの検出文字と画像説明を参照できる。
- 「一般」のアプリ言語設定を Speech、WhisperKit、画像内テキストの共通候補として使う。画像説明は要約言語で生成し、設定変更は将来の画像解析にだけ適用する。
- screenshot 検索は `ocr` と `caption` の両カラムを対象とし、BM25 で caption に ocr より低い重み（0.4）を与える。caption は AI 生成の解釈であり、実際の検出文字より信頼度が低いため。

## Consequences

- 要約から参照されない画像も検索できる一方、全画像分の Codex 処理量と DB 容量が増える。
- 画像解析 failure は当該 screenshot job に保持され、meeting/project FTS の利用可否を失敗させない。
- FTS projection は v38 migration で再構築され、再構築完了までは検索 unavailable になる。

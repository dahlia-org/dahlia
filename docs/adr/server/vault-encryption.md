# Server Vault content encryption

2026-09-10 の判断。対象は Server canonical DB の保存形式と鍵管理。設定と運用コマンドの正本は [Server README](../../../apps/server/README.md#server-vault-encryption)。

## 決定と理由

新規 Vault だけに `none` / `server` を選択可能にする。目的は DB を直接参照した際の canonical 本文の露出を減らし、既存の検索を維持すること。Server は信頼境界内であり、認可後の API・同期・job には復号した通常のデータを返す。E2EE や Server 管理者からの秘匿ではない。

Vault ごとにランダムな 256-bit DEK を生成し、環境変数の master key で AES-256-GCM wrap する。PostgreSQL は `crypto.vault_keys`、SQLite は `vault_keys` に wrapped DEK のみを保存する。PostgreSQL では 現在のVault読取権限に基づく RLS と FORCE RLS を適用する。各 envelope は version、key ID、ランダム nonce、認証 tag 付き ciphertext を持ち、AAD は Vault、table、primary key、field と envelope の version / key ID に結び付ける。

暗号化は非同期 store encode/decode 層が所有する。Drizzle customType に暗号処理を入れず、API adapter の個別処理や自動 proxy に分散させない。transaction 内で DEK を共有し、partial update は既存の暗号化フィールドを保持する。鍵や ciphertext の欠損・改ざんは復号エラーとし、平文へ fallback しない。

## 保護範囲

Vault / Project / Meeting の名前と説明、Meeting の Calendar Event スナップショット、全世代の summary・transcript 本文と metadata、話者名、file 名・URI・checksum・OCR 等の metadata、staged transcript chunks、Transaction receipt の内容、summary job の設定・入力・中間結果を暗号化する。比較が必要な private hash は DEK 由来の鍵で HMAC 化する。ID、関係、revision、日時、状態、file の source discriminator 等の処理用情報は平文に残る。

**検索の例外は明示的に承認されたもの:** PostgreSQL / Lakebase の `search.documents`、SQLite の `search_documents` とその全文・vector 索引は暗号化対象外とする。検索テキスト、会議名、要約、OCR、caption、入力 hash、model、vector は DB 直接参照で読める。検索対象の内容を DB 全体から秘匿する保証はしない。ベクトルを文書へ統合し、独立した `search_embeddings` と暗号化用の復号 scan は削除する。DB 側の検索と既存 RRF を再利用し、Vault 認可・RLS / FORCE RLS は維持する。

file / recording 本体、device DB、認証・credential 表はこの暗号化の対象外。object storage 自体の保護は別の運用境界である。

## 制約と rollout

既存 Vault の mode 変更と暗号化が関係する Vault transfer は v1 では拒否する。旧データ・旧 backup を暗号化したと誤認させないため、in-place migration は実装しない。Server は未リリースのため、2026-09-10 に承認された初期 migration の直接更新へ統合する。既存の開発 DB は別途明示的な再構築または移行が必要で、起動時に自動破棄しない。

master key は個別の番号付き runtime secret とし、active ID を明示する。鍵は DB と別管理し、rotation は DEK の再 wrap のみを再開可能なバッチで行う。削除 Vault の key は receipt の再送検証・保持期間処理のため残す。旧 backup が必要とする master key を live rotation の完了だけで削除しない。

外部 KMS、既存 Vault の暗号化 mode 変換、暗号化検索 index は今回の範囲に含めない。

`embedding_text` の重複保存列は削除する。embedding 入力は既存の検索用 `search_text` から取得し、その hash の一致を生成開始時と保存時で確認する。検索の hash 管理、NULL による vector 無効化、model 切替は [検索 ADR](search.md#hybrid-検索)、既存開発 DB の更新手順は [Server README](../../../apps/server/README.md#updating-an-existing-development-database) を参照。

Vault keyのidentityはVault IDのみ。鍵の作成・更新には対応する操作権限を要求する。rotation、retention、削除後receipt、governance名の読取には用途を限定したmaintenance contextを使い、通常の本文アクセスへ拡張しない。

# Desktop v2（Electron、独立実装）

対象: Desktop v2（`apps/desktop-v2`）。作成: 2026-11-20。ユーザーの依頼により実装した開発版。下記「Tenet との関係」の T3・T1 / T4 の例外は、2026-11-20 にユーザーが「この開発版に限り例外を承認」と明示承認した。承認はこの独立した開発版に限定し、既存クライアントや製品全体には適用しない。`PRODUCT.md` は変更しない。計画と未検証事項は [Desktop v2 計画](../../plans/2026-11-20-desktop-v2.md)。

## 決定

Server・`packages/ui`・Electron アルファ（`apps/desktop`）と共有しない独立の Electron アプリとして、録音・Mac での文字起こし・要約だけを持つ。

- 識別とデータ: `com.dahlia.desktop-v2`、名称 Dahlia v2、`~/Library/Application Support/dahlia-v2/`（`dahlia-v2.sqlite` と `recordings/`）。Swift 版・アルファ版のデータを読まず、移行しない。
- 認証: Databricks Workspace OAuth のみ、1 件。Swift 版と同じ public client `databricks-cli`、scope `offline_access all-apis`、PKCE、`localhost:8020`〜`8040` の loopback。credential は Electron の `safeStorage` で暗号化したファイルに置く。
- 録音: renderer の `getUserMedia`（マイク）と `getDisplayMedia` の loopback 音声（システム音声）を 16 kHz・モノラル・16 bit に変換し、main process が音源ごとのヘッダーなし PCM に追記して 5 秒ごとに fsync する。
- 文字起こし: 同梱の Swift CLI `dahlia-transcribe` を子プロセスで実行し、Apple Speech（`SpeechAnalyzer` + `SpeechTranscriber`、`preset: .transcription`）で処理する。結果は JSON Lines で受け取る。ネイティブアドオンは採らない。認識側の異常終了が録音を持つ main process を巻き込むためである。音源ごとに順に実行し、5 分間出力がなければ止める。
- 要約: Pi を使わず、main process から Workspace の AI Gateway（Anthropic Messages API、`claude-*` のみ）を呼び、tool の入力 schema で JSON に固定する。

## Tenet との関係

- **T5「認証を中核機能の前提にしない」**: 初回・サインアウト後も録音・文字起こし・閲覧・設定を利用できる。認証方式は Databricks のみで、要約の利用時にサインインする。サインイン画面は閉じてローカル操作へ戻れる。ネットワークが要るのは要約と、初回の音声認識モデル取得だけ。
- **T3 の録音保全**: [録音ストレージ](recording-storage.md) の segment・状態機械・digest 検証は持たない。追記のみの PCM を 5 秒間隔のタイマーで fsync する。クラッシュ時には capture・IPC の未保存バッファも失われるため、損失時間の上限や UI 停止時の保全は保証しない。書き込み・fsync の失敗や入力切断では録音を止めて表示し、保存済みファイルを保持する。通常停止と終了確認後は worklet の残りを送信してからファイルを閉じる。起動時に録音中のまま残った録音はファイル長から閉じて文字起こしへ進める。
- **T1 / T4**: MCP を持たない。

## 理由と制約

既存の Swift 版は機能が多く、Electron アルファは Server 前提のため、最低限の録音と要約を独立して動かす土台を別に作る。音声は Mac の外に出さない（文字起こしは端末内）。配布の署名・公証・自動更新、データ移行、ライブ文字起こし、AI チャットは対象外。ライブ文字起こしを足す場合も別プロセスのまま、CLI に標準入力から音声を受ける常駐モードを加える。

# 文字起こし・要約の処理場所

対象: Desktop / Server / Private Web。採択: 2026-09-10。

## 決定

文字起こしと要約を別々の処理方式として選ばせず、アカウントごとに `local` / `remote` の処理場所を選ぶ。Local Account は `local` 固定とし、Server Account は `account_settings.summary.mode` を全DesktopとWebで共有する。Serverにローカルモデル設定は保存しない。

`local` はApple Speechで確定文字起こしを作り、内蔵Codexで要約する。Server VaultでもServer要約APIを呼ばない。Codexの接続先はVaultのアカウントcontextを使うが、要約モデル・推論強度・詳細度・出力言語はこのMacのLocal Account共通設定を使う。

`remote` は保存・同期済み録音をServerで処理する。`remote.transcriptionModel` があれば先に文字起こししてから選択した要約モデルへ渡し、なければ音声対応・構造化出力対応Geminiの1回の生成で文字起こしと要約を作る。失敗時に処理場所を自動変更しない。

録音開始時に処理場所と設定を `recording_sessions.processingJSON` へ固定する。Server設定が未取得でも録音開始を妨げず、ローカル処理を選ぶ。開始済み処理の再起動・再試行は保存済み要求と段階を使う。

## 設定と移行

Server設定は `summary: { mode, remote: { detail, model, reasoningEffort, transcriptionModel? } }` とする。PATCHの省略は維持、`transcriptionModel: null` は削除である。旧 `transcript` は `local`、`cloudTranscription` は `remote` の二段階、`audio` は `remote` の一括生成へforward migrationする。公開APIに旧形式の互換アダプターは置かない。

DesktopのLocal Account設定は既存UserDefaultsを正本とし、初回だけ最後に開いたLocal Account Vaultの要約モデル・推論強度を引き継ぐ。released DB互換と開始済み処理のdecodeのため既存Vault列と内部の旧処理値は残すが、新規処理の選択には使わない。

設定画面は「文字起こしと要約」に統合し、適用対象、保存先、処理場所を先に示す。同期対象の処理場所・remote設定と、このMacだけの録音・Local Account設定を別sectionにする。Webは同じServer設定を編集できるが、`local` では生成を無効にしてDesktop処理であることを示す。

## Product境界

これはT5のクラウド音声処理禁止に対する明示的な例外である。例外はServer Accountで利用者が `remote` を選んだ保存済み録音の後処理だけに限定する。capture、録音保存、Local Account、`local` 処理をServerやnetworkへ依存させず、外部障害で録音・既存の文字起こし・要約を失わない。

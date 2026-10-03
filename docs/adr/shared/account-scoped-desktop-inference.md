# アカウント別の Desktop 推論と操作元による実行場所

採択: 2026-10-02。ユーザー承認済み。

[処理場所](transcription-summary-processing.md)の location 選択・Mac共通推論・Server再文字起こしと、
[アカウント](../desktop/accounts.md)のモデル設定スコープ・drainして切替・独立Mac推論ランタイムを置き換える。

## 決定

Desktopの文字起こし・再文字起こしはApple Speech、要約・画像解析は内蔵Codex app-serverで行う。
LocalはChatGPTまたは直接Databricks、Serverアカウントは自身のGatewayに固定する。データの所属と認可は
Workspaceのconnection IDから判定し、モデルプロバイダーから推定しない。

生成用app-serverは選択中アカウントの1プロセスとし、別アカウントへ切り替えると受付を閉じ、実行中処理を取消し、
旧プロセスを停止する。次の処理時に既存のアカウント別CODEX_HOMEで起動する。同じアカウント内のWorkspace切替では停止しない。
チャット・要約の中断は明示的な再実行、画像は元アカウントに戻ると永続キューから再試行する。
未開始の要約は対象アカウントを待つ。録音・文字起こし・保存済み結果はCodex停止から独立させる。
同一アカウントのプロバイダーや接続プロファイルが変更済みなら、古い要約要求は失敗として再実行を促す。
選択した設定の適用中は完了まで待ち、適用に失敗した場合は待機を解除してエラーにする。
履歴や認証を別homeへコピーせず、アカウント切替で履歴の表示範囲だけを変更する。認証管理用の既存サービスは生成に使わない。

このMacのUserDefaultsへLocal／接続UUID別に、チャット・要約のモデルと推論強度、要約スタイル、録音後の自動処理、
live draftを保存する。初回は同じアカウントの最後に開いたWorkspaceから引き継ぎ、それ以降は同期で上書きしない。
DesktopとWebで共有するWorkspaceの既定値は出力言語のみとする。サーバー用のモデル・推論強度・音声処理方法・要約スタイルは、Webから明示的に生成する場合のWorkspace既定値として維持する。実行時に上書きでき、Desktopのアカウント設定には適用しない。Desktopで生成した結果を同期で受け取ってもサーバーで自動生成しない。モデル一覧から選択モデルが消えても保存値は変更せず、その要求だけ既定へ戻す。

Desktop要約は文字起こしを入力ソースとする（既存のノート・画像補助は維持）。音声からの直接要約は提供せず、
再文字起こしと要約を別操作にする。手元の音声が削除済みなら既存の認可・checksum検証付きアーカイブ取得経路でM4Aを取得する。
全文の成功前に既存文字起こしを置き換えない。

Webから明示的に開始した文字起こし・要約は既存Serverキューを使う。同期や不足データの巡回だけではServer画像解析を登録しない。
Webの画像解析操作は今回追加しない。検索・Memory・Gatewayの推論リレーは引き続きServerが担当する。

## 互換性とデータ保護

v0.24.xのprocessingJSONはremote・audio・cloudTranscription・serverRequestを含めて読み取る。旧remote処理は再開せず、
Macで再実行できる失敗として表示する。不正JSONは該当録音だけをスキップして通知し、他の録音の復元を続ける。
旧DB列と登録済みmigrationは変更しない。

Server設定の既知の旧キーは受け付け、旧クライアントが読める応答形状を維持する（案A）。未知のキーは拒否する。
旧キーを新しい実行場所判定に使わない。旧imageAnalysis要求も同期の互換入力として受け付け、AI生成は登録しない。
要約の保存と同期要求は同じローカルtransactionで確定し、revision競合では未同期結果を保持する。
明示的なServer版の採用まで、[RemoteChangePolicy.permits](../../../apps/macos/Sources/Dahlia/Services/RemoteChangePolicy.swift)と
[SyncTransactionQueue](../../../apps/macos/Sources/Dahlia/Database/SyncTransactionQueue.swift)の既存保護を維持する。
保存と同期要求の原子性は[MeetingRepository.applyGeneratedSummary](../../../apps/macos/Sources/Dahlia/Database/MeetingRepository.swift)、
競合後もローカル要約を再送できることは[MeetingSyncMigrationTests.reapplyingADeletedMeetingRestoresItBeforeItsSummary](../../../apps/macos/Tests/DahliaTests/MeetingSyncMigrationTests.swift)で確認する。

## T5への適用

Desktop音声処理をMacに統一する。クラウド音声処理の例外は、Webから利用者が明示的に開始した保存済み録音の処理に限定する。
ServerアカウントのGateway利用は音声処理のServer委譲を意味しない。

# 文字起こし・要約の処理場所

対象: Desktop / Server / Private Web。採択・設定スコープ改訂: 2026-09-10。

## 決定

文字起こしと要約を別々の処理方式として選ばせず、アカウントごとに `processing.location: local | remote` を選ぶ。Local Account は `local` 固定。Server Account の設定は全DesktopとWebで共有する。

設定の所有者は次の三つに分ける。

- Macアプリ: ローカル推論のプロバイダー・要約モデル・推論強度、録音と端末機能。ローカルアカウントには紐付けず、どのアカウントの `local` 処理でも同じMac設定を使う。Serverには保存しない。
- Local Account: 要約スタイル・出力言語。既存UserDefaultsを使う。
- Server Account: 処理場所・要約スタイル・出力言語・画像解析言語、サーバー処理の詳細設定。

`local` はApple Speechで確定文字起こしを作り、内蔵Codexで要約する。Server VaultでもServer要約APIを呼ばず、Macの推論プロバイダーを使う。スタイルと言語は対象アカウントの設定を使う。チャットのVault/Gateway contextとMac推論contextを分離し、推論先からデータの所属アカウントを推定しない。

`remote` は保存・同期済み録音をServerで処理する。新しい録音後の自動処理は既定で `combined`（Geminiが音声から直接要約し、同じ処理で文字起こしも生成）とし、`transcribeThenSummarize`（Geminiで文字起こし後、その文字起こしから要約）も選べる。Server文字起こしでは保存済みの言語設定を送らずGeminiが処理中に判定する。`combined` だけ要約モデルと推論強度を上書きでき、二段階処理は文字起こし用Geminiと文字起こし要約に対応するモデルをそれぞれ自動選択する。モデルの有無で処理方式を推定せず、失敗時に処理場所を自動変更しない。

録音開始時に処理場所と設定を `recording_sessions.processingJSON` へ固定する。Server設定が未取得でも録音開始を妨げず、ローカル処理を選ぶ。開始済み処理の再起動・再試行は保存済み要求と段階を使う。

手動要約では、対象会議が属するServerアカウントの設定を取得してから処理場所と出力設定を固定する。取得できなければエラーとし、Mac処理へ切り替えない。再試行でも取得済みの設定を使い、現在開いている保管庫の設定を借用しない。

手動生成の入力ソースはアカウント設定に保存せず、会議ごとの実行時設定とする。最新の確定文字起こしに非空セグメントがあれば `transcript` を既定とし、なければ全対象録音の確定済みアーカイブが揃った場合だけ `audio` を既定とする。`transcript` は要約だけを置き換え、`audio` は文字起こしと要約を置き換える。複数会議では全件で利用できるソースだけ選べ、一部の録音だけを使う生成は行わない。Local処理は `transcript` のみ、Remote処理ではServer capabilityに含まれるソースだけを選べる。`audio` の手動選択は、`meetingSummaryGeneration.completeRecordings` が完全な録音集合の検査を保証するServerだけで有効にする。既存のv2機能と自動処理設定はこの追加保証の有無にかかわらず維持する。

## 2026-09-16 の再文字起こし境界

初回処理の設定と明示的な再文字起こしを分離する。Local Workspace の再文字起こしは保持中の CAF（既存録音では互換 M4A も可）を
使い、区間別の自動言語判定と Apple Speech で全文を再生成する。Server Account 配下の Workspace は、初回の処理方法に
かかわらず確定・アップロード済み M4A を使い、音声対応 Gemini だけで全文を再生成する。Server 再文字起こし要求には
保存済み言語設定を含めず、言語判定も Gemini に委任する。Gemini の失敗を Apple Speech、ローカル処理、別 provider へ
暗黙にフォールバックしない。

既存 summary job API の録音入力に任意リテラル `transcriptionOnly: true` を追加し、既存 queue、lease、最大試行、取消、
競合検出を再利用する。Server はこの要求で文字起こしだけを atomic に置換し、要約生成へ進まず既存要約を変更しない。
Desktop は `meetingSummaryGeneration.retranscription: { version: 1, provider: "gemini" }` を広告する Server にだけ要求し、
完全な録音集合のアップロードが未完了・失敗なら既存結果を保持して操作を無効化する。処理用途は
`recording_sessions.processingJSON` の任意フィールドへ保存し、DB 列を追加せず旧データの decode を維持する。

## 設定と移行

アカウント設定は次の構造とする。

```typescript
{
  outputLanguage,
  analysisLanguages,
  summary: { style: "concise" | "standard" | "detailed" | "eventSummary" | "eventTimeline" },
  processing: {
    location: "local" | "remote",
    remote: {
      workflow: "transcribeThenSummarize" | "combined",
      summaryModel?, reasoningEffort?
    }
  }
}
```

スタイルはユーザーの意図であり、モデルAPIのreasoning effortや内部jobのdetail値とは別物。実行境界で既存の `low/medium/high/xhigh/max` に変換する。モデル・推論強度の省略は「自動」。Serverは利用可能な既知の推奨モデルとcatalogのdefault effortから実行値を確定する。catalog順で未知のモデルを選ばず、明示した値が利用不可ならエラーとする。ただし手動生成で保存モデルが選択ソースに非対応の場合は、保存値を変更せず、その要求だけ要約モデルと推論強度を「自動」に戻す。

PATCHの省略は維持。要約モデル・推論強度overrideは `null` で自動へ戻せるが、workflowとstyleはnull不可。場所・方式の切替は非アクティブなoverrideを削除しない。生成要求には入力とpreferencesのsnapshotを送り、Serverは受付時に実行値を固定する。既存job要求・保存済み処理の読み取り互換は維持し、retryで現在の設定へ置換しない。

初回リリース前の Server は従来の `summary.mode/remote`、transcriptionModel、Workspace の言語設定を変換する forward migration を配布せず、現行形式を initial baseline に統合する。既存開発 DB の自動変換は提供しない。公開アカウント設定APIに旧形式の互換アダプターは置かず、Server/Web/Desktopを合わせて更新する。

Mac設定は既存UserDefaultsを正本とし、初回だけ最後に開いたLocal Account Vaultの要約モデル・推論強度を引き継ぐ。保存キー・既存Vault列・内部の旧処理値は移行および開始済み処理のdecodeのため残す。

Macのモデルを明示的に変更したときだけ、以前の推論強度が非対応ならモデル一覧の既存選択規則に従って対応値へ合わせる。画面の表示やモデル一覧の再取得だけでは保存値を変更しない。

設定画面は「このMac」と「アカウント設定」を分離する。MacのAI接続先・モデルは「このMacのAI」、スタイル・言語・処理場所は「要約と画像解析」に置く。後者は開いているアカウントを初期選択し、保管庫を切り替えずに編集対象アカウントを選べる。画面に対象と適用範囲を示し、通常操作は生成結果の好み、次に処理場所、モデルとworkflowは詳細設定とする。workflowは「新しい録音の自動処理」と明記し、手動生成では会議画面のソース選択が優先されることを説明する。設定の閲覧・対象選択だけでは保管庫の所属や推論設定を変更しない。Webもアカウントの本人情報を先に示し、同じ順序で設定を表示する。`local` は完全な端末内推論を意味せず、接続AIへの文字起こし・画像送信を説明する。Webでは`local`の生成を無効にする。

## Product境界

これはT5のクラウド音声処理禁止に対する明示的な例外である。例外はServer Accountで利用者が `remote` を選んだ保存済み録音の後処理だけに限定する。capture、録音保存、Local Account、`local` 処理をServerやnetworkへ依存させず、外部障害で録音・既存の文字起こし・要約を失わない。

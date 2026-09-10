# 文字起こし・要約の処理場所

対象: Desktop / Server / Private Web。採択・設定スコープ改訂: 2026-09-10。

## 決定

文字起こしと要約を別々の処理方式として選ばせず、アカウントごとに `processing.location: local | remote` を選ぶ。Local Account は `local` 固定。Server Account の設定は全DesktopとWebで共有する。

設定の所有者は次の三つに分ける。

- Macアプリ: ローカル推論のプロバイダー・要約モデル・推論強度、録音と端末機能。ローカルアカウントには紐付けず、どのアカウントの `local` 処理でも同じMac設定を使う。Serverには保存しない。
- Local Account: 要約スタイル・出力言語。既存UserDefaultsを使う。
- Server Account: 処理場所・要約スタイル・出力言語・画像解析言語、サーバー処理の詳細設定。

`local` はApple Speechで確定文字起こしを作り、内蔵Codexで要約する。Server VaultでもServer要約APIを呼ばず、Macの推論プロバイダーを使う。スタイルと言語は対象アカウントの設定を使う。チャットのVault/Gateway contextとMac推論contextを分離し、推論先からデータの所属アカウントを推定しない。

`remote` は保存・同期済み録音をServerで処理する。通常は `transcribeThenSummarize`（文字起こし後に要約）、詳細設定で `combined`（音声対応・構造化出力対応Geminiによる一括生成）を選べる。モデルの有無で処理方式を推定しない。失敗時に処理場所を自動変更しない。

録音開始時に処理場所と設定を `recording_sessions.processingJSON` へ固定する。Server設定が未取得でも録音開始を妨げず、ローカル処理を選ぶ。開始済み処理の再起動・再試行は保存済み要求と段階を使う。

手動要約では、対象会議が属するServerアカウントの設定を取得してから処理場所と出力設定を固定する。取得できなければエラーとし、Mac処理へ切り替えない。再試行でも取得済みの設定を使い、現在開いている保管庫の設定を借用しない。

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
      summaryModel?, transcriptionModel?, reasoningEffort?
    }
  }
}
```

スタイルはユーザーの意図であり、モデルAPIのreasoning effortや内部jobのdetail値とは別物。実行境界で既存の `low/medium/high/xhigh/max` に変換する。モデル・推論強度の省略は「自動」。Serverは利用可能な既知の推奨モデルとcatalogのdefault effortから実行値を確定する。catalog順で未知のモデルを選ばず、明示した値が利用不可ならエラーとする。

PATCHの省略は維持。三つのモデル・推論overrideは `null` で自動へ戻せるが、workflowとstyleはnull不可。場所・方式の切替は非アクティブなoverrideを削除しない。生成要求には入力とpreferencesのsnapshotを送り、Serverは受付時に実行値を固定する。既存job要求・保存済み処理の読み取り互換は維持し、retryで現在の設定へ置換しない。

Forward migrationで従来の `summary.mode/remote` を新しいprocessing列とsummary.styleへ分ける。従来のtranscriptionModelの有無は移行時だけworkflow判定に使う。言語、明示モデル、推論強度、要約の意味を保持する。公開アカウント設定APIに旧形式の互換アダプターは置かず、Server/Web/Desktopを合わせて更新する。

Mac設定は既存UserDefaultsを正本とし、初回だけ最後に開いたLocal Account Vaultの要約モデル・推論強度を引き継ぐ。保存キー・既存Vault列・内部の旧処理値は移行および開始済み処理のdecodeのため残す。

Macのモデルを明示的に変更したときだけ、以前の推論強度が非対応ならモデル一覧の既存選択規則に従って対応値へ合わせる。画面の表示やモデル一覧の再取得だけでは保存値を変更しない。

設定画面は「このMac」と「アカウント設定」を分離する。MacのAI接続先・モデルは「このMacのAI」、スタイル・言語・処理場所は「要約と画像解析」に置く。後者は開いているアカウントを初期選択し、保管庫を切り替えずに編集対象アカウントを選べる。画面に対象と適用範囲を示し、通常操作は生成結果の好み、次に処理場所、モデルとworkflowは詳細設定とする。設定の閲覧・対象選択だけでは保管庫の所属や推論設定を変更しない。Webもアカウントの本人情報を先に示し、同じ順序で設定を表示する。`local` は完全な端末内推論を意味せず、接続AIへの文字起こし・画像送信を説明する。Webでは`local`の生成を無効にする。

## Product境界

これはT5のクラウド音声処理禁止に対する明示的な例外である。例外はServer Accountで利用者が `remote` を選んだ保存済み録音の後処理だけに限定する。capture、録音保存、Local Account、`local` 処理をServerやnetworkへ依存させず、外部障害で録音・既存の文字起こし・要約を失わない。

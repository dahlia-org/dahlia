# 文字起こし・要約の処理場所

対象: Desktop / Server / Private Web。採択: 2026-09-10。

Desktop の実行場所、AI 設定のスコープ、生成 runtime の切替は [アカウント別 Desktop 推論](account-scoped-desktop-inference.md) に従う。本文は処理場所（local / remote）、Server Account の生成設定、再文字起こし、設定の構造を定める。

## 決定

文字起こしと要約を別々の処理方式として選ばせない。Desktop で開始した文字起こしと要約は常に Mac で行い（`local`）、Desktop に処理場所の選択はない。Server での処理（`remote`）は、Web から明示的に開始した保存済み録音だけに使う（[アカウント別 Desktop 推論](account-scoped-desktop-inference.md)）。Local Account の処理場所は `local` 固定とする。Web 用の生成設定は Workspace の `generationSettings` に保存する。Desktop と共有する Workspace の既定値は出力言語のみとし、設定の所有・保存先は [アカウント別 Desktop 推論](account-scoped-desktop-inference.md) に従う。

`local` はApple Speechで確定文字起こしを作り、内蔵 Pi で要約する。Server Account の要約の推論先は自身の Gateway に固定する（[アカウント別 Desktop 推論](account-scoped-desktop-inference.md)）。Desktop の設定の適用範囲は同仕様に従う。チャットの Workspace / Gateway context と Mac 推論 context を分離し、推論先からデータの所属アカウントを推定しない。

`remote` は Web から明示的に開始した保存・同期済み録音を Server で処理する。方式は既定で `combined`（Geminiが音声から直接要約し、同じ処理で文字起こしも生成）とし、`transcribeThenSummarize`（Geminiで文字起こし後、その文字起こしから要約）も選べる。Server文字起こしでは保存済みの言語設定を送らずGeminiが処理中に判定する。`combined` だけ要約モデルと推論強度を上書きでき、二段階処理は文字起こし用Geminiと文字起こし要約に対応するモデルをそれぞれ自動選択する。モデルの有無で処理方式を推定せず、失敗時に処理場所を自動変更しない。

録音開始時に処理場所と設定を `recording_sessions.processingJSON` へ固定する。Server設定が未取得でも録音開始を妨げず、ローカル処理を選ぶ。開始済み処理の再起動・再試行は保存済み要求と段階を使う。

Web の手動要約では、対象会議の Server 側の設定を取得してから出力設定を固定する。取得できなければエラーとする。再試行でも取得済みの設定を使い、現在開いている Workspace の設定を借用しない。

Web の手動生成の入力ソースはアカウント設定に保存せず、会議ごとの実行時設定とする。最新の確定文字起こしに非空セグメントがあれば `transcript` を既定とし、なければ全対象録音の確定済みアーカイブが揃った場合だけ `audio` を既定とする。`transcript` は要約だけを再生成し、`audio` は文字起こしと要約を再生成する。複数会議では全件で利用できるソースだけ選べ、一部の録音だけを使う生成は行わない。Local処理は `transcript` のみ、Remote処理ではServer capabilityに含まれるソースだけを選べる。`audio` の手動選択は、`meetingSummaryGeneration.completeRecordings` が完全な録音集合の検査を保証するServerだけで有効にする。既存のv2機能と自動処理設定はこの追加保証の有無にかかわらず維持する。

## 再文字起こしの境界

Local Workspace の再文字起こしは保持中の CAF（既存録音では互換 M4A も可）を使い、区間別の自動言語判定と Apple Speech で全文を再生成する。

Web から明示的に開始した文字起こし・要約は、[アカウント別 Desktop 推論](account-scoped-desktop-inference.md) に従い既存の Server キューを使う。

## 設定と移行

Web から開始する Server 処理の設定は次の構造とする。

```typescript
{
  outputLanguage,
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

`processing.location` は保存形式として残る。Server は既知の旧キーを受け付ける（[互換性とデータ保護](account-scoped-desktop-inference.md#互換性とデータ保護)）。

スタイルはユーザーの意図であり、モデルAPIのreasoning effortや内部jobのdetail値とは別物。実行境界で既存の `low/medium/high/xhigh/max` に変換する。モデル・推論強度の省略は「自動」。Serverは利用可能な既知の推奨モデルとcatalogのdefault effortから実行値を確定する。catalog順で未知のモデルを選ばず、明示した値が利用不可ならエラーとする。ただし手動生成で保存モデルが選択ソースに非対応の場合は、保存値を変更せず、その要求だけ要約モデルと推論強度を「自動」に戻す。

設定の更新は管理者による `workspace:update` とし、[同期の transaction と競合](sync.md#transaction-と競合) に従って `baseRevision` を照合する。不一致は `409` とし、暗黙に後勝ちで上書きしない。設定の wire schema は [workspaceGenerationSettingsSchema](../../../packages/ui/src/model/workspace-generation-settings.ts) を正本とする。場所・方式の切替は非アクティブなoverrideを削除しない。生成要求には入力とpreferencesのsnapshotを送り、Serverは受付時に実行値を固定する。既存job要求・保存済み処理の読み取り互換は維持し、retryで現在の設定へ置換しない。

Server は初回リリース前の現行形式を initial baseline として持つ。従来の `summary.mode/remote`、transcriptionModel、Workspace の言語設定を変換する forward migration は配布しない。既存開発 DB の自動変換は提供しない。Server / Web / Desktop の契約更新は [OpenAPI の仕様](../server/openapi.md) に従う。

保存キー・既存 Workspace 列・内部の旧処理値は、移行と開始済み処理の decode のため残す。

Mac のモデルを明示的に変更したときだけ、以前の推論強度が非対応ならモデル一覧の既存選択規則に従って対応値へ合わせる。画面の表示やモデル一覧の再取得だけでは保存値を変更しない。

Desktop の設定画面と適用範囲は [アカウント](../desktop/accounts.md) と [アカウント別 Desktop 推論](account-scoped-desktop-inference.md) に従う。Web はアカウントの本人情報と設定の対象を示し、workflow を「要約方法」として要約モデルの直前に置く。Web から明示的に開始する処理の既定値であることを説明し、生成では会議画面のソース選択を優先する。設定の閲覧・対象選択だけでは Workspace の所属や推論設定を変更しない。`local` は完全な端末内推論を意味せず、接続 AI への文字起こし・画像送信を説明する。Web では `local` の生成を無効にする。

## Product境界

これは T5 のクラウド音声処理禁止に対する明示的な例外である。例外は Web から明示的に開始した保存済み録音の処理だけに限定する。capture、録音保存、Local Account、`local` 処理を Server や network へ依存させず、外部障害で録音・既存の文字起こし・要約を失わない。

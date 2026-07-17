# 文字起こしタイムスタンプを録音開始からの相対時間に変更する

## Context

現在、文字起こしセグメントのタイムスタンプは壁時計の絶対時刻(`HH:mm:ss`、例: `14:23:07`)で表示・出力されている。これを録音開始からの経過時間(`00:12:34` 固定幅ゼロ埋め)に変更する。

**確定済みの要件:**

- 変更範囲: 画面表示 + 全エクスポート(テキスト、Obsidian/Markdown、LLM 要約入力の `<time>` タグ)
- フォーマット: `00:12:34` 固定幅(常に HH:mm:ss 形式、8文字幅維持)

**前提となる事実(調査済み):**

- セグメントの `startTime` は `Date`(絶対時刻)だが、生成時に `recordingStartTime + range.start.seconds` で作られている(`Sources/Dahlia/Speech/SpeechTranscriberService.swift:121-126`)ため、基準時刻との差分で相対秒数を正確に復元できる。データモデル・DB スキーマの変更は不要。
- 基準時刻は `TranscriptStore.recordingStartTime`(`Sources/Dahlia/Models/TranscriptStore.swift:16`)。録音開始時に `Date()` がセットされ(`CaptionViewModel.swift:974`)、過去ミーティング読み込み時は `loaded.createdAt` がセットされる(`CaptionViewModel.swift:485`)。したがってライブ中・閲覧時とも同じ基準で計算できる。
- 画面表示は `TranscriptRowView` の1箇所のみで、ライブ中・過去ミーティング閲覧の両方で共通(両方とも相対時間表示に変わる。これは意図した挙動)。ライブ字幕オーバーレイにタイムスタンプ表示はない。
- `Formatters.timeHHmmss` の使用箇所は今回変更する4箇所のみ → 置き換え後に削除できる。

## 変更内容

### 1. 経過時間フォーマッタを追加し、`timeHHmmss` を置き換える

`Sources/Dahlia/Models/TranscriptSegment.swift` の `Formatters` enum(3-10行目):

```swift
enum Formatters {
    /// 録音開始からの経過時間を "00:12:34" 固定幅(HH:mm:ss)で整形する。
    static func elapsedHHmmss(from start: Date, to date: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
```

`timeHHmmss` は全使用箇所が置き換わるので削除する(削除前に grep で未使用を再確認)。
※ `ControlPanelView` の `ScreenshotThumbnailView.timeFormatter` と `SummaryService.timeFormatter` はスクリーンショットのキャプチャ時刻用の別物なので触らない。

### 2. 画面表示: `TranscriptRowView` + `TranscriptTabView`

- `Sources/Dahlia/Views/TranscriptRowView.swift`
  - `let timeBase: Date` プロパティを追加(`Date` は `Equatable` なので `View, Equatable` の合成 `==` はそのまま維持され、`ForEach` 側の `.equatable()` 最適化も有効なまま)。
  - 11行目のタイムスタンプ表示を `Text(Formatters.elapsedHHmmss(from: timeBase, to: segment.startTime))` に変更。`frame(width: 56)` は8文字幅のままなので変更不要。
- `Sources/Dahlia/Views/TranscriptTabView.swift`
  - 基準時刻の computed property を追加: `store.recordingStartTime ?? store.segments.first?.startTime`(recordingStartTime は通常必ずセットされるが、防御的フォールバックとして先頭セグメント基準 = 先頭が 00:00:00 になる)。
  - `ForEach`(79-85行目)で `TranscriptRowView(segment:timeBase:showsTranslatedText:)` に渡す(`?? segment.startTime` で non-optional 化)。

### 3. エクスポート3箇所

- `Sources/Dahlia/Models/TranscriptStore.swift`
  - `exportAsText()`(139行目)と `exportForSummary()`(148行目): map の外で `let base = recordingStartTime ?? segments.first?.startTime ?? Date()` を1回計算し、`Formatters.elapsedHHmmss(from: base, to: segment.startTime)` に置き換え。
- `Sources/Dahlia/Services/TranscriptExportService.swift`
  - `exportTranscript`(40行目): 既に引数で受け取っている `createdAt`(呼び出し元 `CaptionViewModel.swift:1295` / `VaultSummaryExportService.swift:62` はいずれもミーティングの `createdAt` = 録音開始時刻を渡している)を基準に `Formatters.elapsedHHmmss(from: createdAt, to: segment.startTime)` へ置き換え。

### 4. テスト追加

`Tests/DahliaTests/` に Swift Testing(`@Test` / `#expect`)で追加(規約: `Tests/DahliaTests/CLAUDE.md`):

- `Formatters.elapsedHHmmss`: 0秒 → `00:00:00`、1時間未満 → `00:12:34`、1時間以上 → `01:05:47`、開始より前(負値)→ `00:00:00` にクランプ。
- `TranscriptStore.exportAsText()` / `exportForSummary()`: `recordingStartTime` をセットした状態で相対時間が出力されること。既存の `Tests/DahliaTests/TranscriptSegmentTests.swift` に追記するか、近い場所に新ファイルを作る。

UI 文字列の追加はないため L10n / Localizable.strings の変更は不要。DB マイグレーションも不要。

## 検証

1. `swift build` が通ること。
2. `swift test`(または `--filter TranscriptSegmentTests` 等)— **この Mac では swift test が exit 0 のまま未実行になることがあるため、必ず「Test run with N tests」等の集計行が出力されていることを確認する。**
3. `./scripts/lint.sh`(SwiftFormat + SwiftLint)が通ること。
4. 動作確認: `./scripts/run-dev.sh` で起動し、(a) 録音開始直後のセグメントが `00:00:xx` から始まること、(b) 過去ミーティングを開いたときも先頭付近が `00:00:xx` になること、(c) テキストエクスポートの出力が相対時間になっていることを確認。

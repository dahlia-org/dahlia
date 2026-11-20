# macOS アプリの応答性：構成の作り直し

対象: macOS アプリ（`apps/macos`）。Local Account / Server Account 共通。`packages/ui` に表示部品を追加する。
状態: 計画確定。2026-11-20 に 5 章の判断 5 件をユーザーが承認した。実装は未着手で、着手の指示を待つ。
前提: 変更量の少なさは判断基準にしない。録音・確定文字起こし・保存の経路（recording-critical / durable）は変更しない。

この計画はコードの読解と、この Mac に残っていた診断レポート 2 件に基づく。Instruments による実測はまだ無い。
実測で覆る可能性がある判断には「未計測」と書いた。

## 1. 診断

過去のハング対策は、症状が出た画面ごとに「非同期化・間引き・世代番号」を足す形で行われた。
原因は画面の外に 3 つあり、そこが残っているため、対策を足すほど遅延と複雑さだけが増えている。

### 原因 A: 主データベースが 1 本の直列キュー

- 主 DB は `DatabaseQueue` 1 本（`Database/AppDatabaseManager.swift:51`）。別の読み取り接続を持つのは検索だけ（同 `:84-89`）。
- 画面の読み取り、22 箇所の `ValueObservation` の再取得、確定文字起こしの書き込み、同期、索引の再構築が同じ列に並ぶ。
- `Task.detached` で包んでも、読み取りは書き込みの後ろで待つ。待ち時間が MainActor の外へ移るだけで、表示は遅いままになる。
- MainActor 上の同期 DB 呼び出しも残っている（`ViewModels/CaptionViewModel.swift:1285`, `:1775`, `:2374`, `:2477`, `:4674`）。書き込み待ちの間、画面が止まる。
- 録音中は、確定文字起こしの commit のたびに meeting sync の観測が再実行される（同 `:2847-2881`、コード内コメントのとおり）。
- 実データ: `/Library/Logs/DiagnosticReports/Dahlia_2026-11-15-000453_*.diag`（v1.3.0）では、`BackgroundJobWorker.rebuild()` の commit が
  189 秒で 2.1 GB を書いた。`Dahlia_2026-11-13-111326_*.diag`（v1.0.2）も同じスタック。
  再構築は 1 件ごとに 2 回 commit する小さな transaction の連続である（`Database/BackgroundJobWorker.swift:424-470`）。
  1 回の待ちは短いが、読み取りは毎回その列に並び直す。どちらも旧バージョンの記録であり、現行 v1.9.0 での量は未計測。

### 原因 B: 状態の購読範囲が広すぎる

- `CaptionViewModel` は 5850 行、`@Published` 44 個の `ObservableObject`。22 個の View が丸ごと購読している。
- 44 個のどれか 1 つが変わると、購読している全 View の body が再評価される。ノートの 1 打鍵（`noteText`）や一括文字起こしの進捗でも、
  サイドバーの一覧まで再評価される（`Views/MeetingListSidebarView.swift:4`）。
- `AppSettings` も `ObservableObject` で、35 箇所が購読している。`@Observable` への移行は 41 クラス対 14 クラスで途中。

### 原因 C: 可変高さ・選択可能・ストリーミングのテキストを、画面ごとに手作りしている

- 文字起こしは行ごとに `NSTextView`（TextKit 1）を作り、`sizeThatFits` のたびに同期レイアウトする（`Views/SelectableTextContent.swift:20-26`）。
  録音中は負荷を避けるため選択を無効にしており（`Views/ControlPanelView.swift:72`）、停止の瞬間に全行を作り直す。
- AI チャットは非 lazy の `VStack` に `NSTextView` を並べ、4096 文字ごとの段階レイアウトで高さを何度も変える
  （`Views/CodexChat/CodexChatConversationView.swift:150-151`, `CodexChatMarkdownTextView.swift:186-254`）。
  解析は全文と末尾の 2 経路が並走する（`CodexChatMarkdownProjectionModel.swift`）。
- ライブ字幕は 1 更新で `NSHostingView` を 2 回強制レイアウトし、全履歴の `LazyVStack` を末尾追従させる
  （`Services/LiveSubtitleOverlayService.swift:111-152`, `:321-359`）。
- 同じ問題（可変高さの長い文書、選択、追記）を 3 通りに解いており、Web 版（`packages/ui`）には 4 つ目の実装がある。

### 画面別の主因

| 画面 | 主因（確認済みの箇所） | 非同期処理の評価 |
| --- | --- | --- |
| サイドバーの過去ミーティング一覧 | 全行が `.global` フレームを毎フレーム `@State` に書く（`MeetingSidebarRow.swift:51-56`）。全行がマーキー用に題名を 2 回レイアウトする（`MeetingTitleMarquee.swift:17-48`）。原因 B | データ経路はおおむね妥当。`Task.detached` と取消しの手書き橋渡しは不要 |
| スクリーンショット一覧 | cache を引く前に原本を全量読み、SHA-256 を計算し、アクセス時刻を書く。cache が当たっても省略されない（`Utilities/ScreenshotImageLoader.swift:57-68`）。読み取りと decode はどちらも直列 | 1 枚あたり 6 層。直列だから必要になった lane 分離と single-flight が過剰 |
| 文字起こし | 原因 C。ページ読み込みの状態機械（世代、revision、waiter、再帰 3 回）。preview の間引きが pipeline と store で二重（`Models/TranscriptStore.swift:570-589`） | pipeline の分離は必要。store 側の間引きと二重ガードが過剰 |
| ライブ字幕 | 原因 C。差分 projector と store が同じ処理を二重に持つ | relay と 200 ms の間引きは必要。`Task.yield` 後の再計測は不要 |
| AI チャット | 原因 C。`messages` 配列 1 個の購読で、20 Hz で会話全体の body を再評価する | 二重の解析経路、cache actor、約 30 箇所の取消し確認が過剰 |

横断の数（`apps/macos/Sources/Dahlia`）: `Task.detached` 63、世代カウンタの宣言 約 65、`Task.yield` 9。
`Task.detached` のうち約 50 は同期 DB 読み取りを包むだけで、GRDB の非同期読み取りに置き換えられる。

## 2. 目標構成

### 柱 1: 読み取りを書き込みから切り離す

- 主 DB を `DatabasePool`（WAL、読み取りは snapshot で並行）にする。画面の読み取りと観測は書き込みを待たなくなる。
- 画面側のコードは `any DatabaseReader` だけを受け取る。書き込みは既存の durable 経路だけが `any DatabaseWriter` を持つ。
  型で分けるので、View や ViewModel から書き込み列に並ぶ読み取りを書けなくなる。
- 検索専用の `searchDBQueue` は不要になるので削除する。
- 観測は `for try await value in observation.values(in: reader)` を所有 Task の中で回す。取消しで止まるので、世代カウンタは要らない。
- 索引の再構築は既に 1 件ごとの transaction なので、分割はしない。逆に、索引の更新と進捗の更新を 1 つの commit にまとめ、
  数十件単位で commit して書き込み量を減らす。1 commit は 50 ms 以下に保つ（未計測）。
- 発展（別判断）: 再生成可能な索引（`search_documents_fts` など）を別ファイルへ移す。正本 DB の WAL と書き込み列から完全に外れ、壊れたら削除して作り直せる。

### 柱 2: 状態を機能ごとの `@Observable` に分ける

`CaptionViewModel` を解体し、View は使う値だけを読む。

| 新しい型 | 持つもの |
| --- | --- |
| `RecordingModel` | 録音の開始・停止・状態、音源、準備状況 |
| `MeetingDetailModel` | 選択中 Meeting の読み込み、同期状態、内容の有無 |
| `SummaryJobsModel` | 要約生成の job と進捗 |
| `ScreenshotModel` | スクリーンショットの一覧と取得対象ウィンドウ |
| `NotesModel` | ノート本文と自動保存 |
| `BatchTranscriptionModel` | 一括文字起こしの状態と進捗 |

- すべて `@MainActor @Observable`。`ObservableObject` の残り 14 クラス（`AppSettings`、`TranscriptStore` を含む）も移行する。
- `CaptionViewModel` は最後に削除する。途中段階では、新しい型へ転送するだけの薄い入口として残してよい。
- 録音 runtime の所有者は `RecordingSessionController` のままにする。

### 柱 3: テキスト表示を 1 つの Web 表示面に寄せる

AI チャットの会話と文字起こしを、`packages/ui` の部品を載せた `WKWebView`（以下 ContentSurface）で表示する。

理由:

1. **描画が別プロセスになる。** Markdown の解析、レイアウト、描画は WebContent プロセスで走る。そこが詰まっても、アプリの MainActor と録音の UI は止まらない。
   現在の ARCHITECTURE は helper process を対象外としているが、描画に限れば WebKit が標準で提供する。
2. **問題の種類がブラウザの得意分野と一致する。** 可変高さの長い文書、行をまたぐ選択、追記時のスクロール位置保持（`overflow-anchor`）、
   画面外の描画省略（`content-visibility: auto`）、表、コードブロック。いま Swift で手作りしている部分がすべて標準機能になる。
3. **実装が 1 つになる。** Web 版と Electron alpha は既に `AiChat.tsx`、`ChatMarkdown.tsx`、`TranscriptHistory.tsx`、`MeetingContent.tsx` を使っている。
   「挙動の変更は全クライアントに反映する」という Definition of Done を、同じ部品で満たせる。
4. **土台がある。** `DocumentWebEditor` が、同梱 JS の読み込み、message handler、高さ通知を実装済み（`Views/DocumentEditorView.swift:446-481`）。

構成:

- `packages/ui` に `content-surface` の IIFE バンドルを追加する（`tsup.documents.config.ts` と同じ方式）。同梱ファイルだけを読み、ネットワークは使わない。
- Swift が正本と操作を持ち、Web は表示だけを持つ。橋渡しは型付きメッセージに限定する。
  - Swift → Web: `reset(snapshot)`、`append(items)`、`patch(id, fields)`、`streamDelta(messageId, text)`、`setTheme(tokens)`
  - Web → Swift: `requestPage(direction, cursor)`、`action(kind, id)`（承認、コピー、リンク、再生位置）、`ready`、`presented(seq)`
- **送信は 1 件ずつ。** Swift は表示面ごとに、前の送信に対する `presented(seq)` を受け取ってから次を送る。
  JavaScript の呼び出しが戻った時点では、描画はまだ予約されただけなので、送信枠を解放しない。
  WebContent が止まっても、WebKit への送信要求は積み上がらない。
  - Web 側は、更新を描画した次の `requestAnimationFrame` で `presented(seq)` を返す。表示面が隠れている間は
    `requestAnimationFrame` が動かないので、DOM へ反映した時点で返す。
- **待っている間の更新は、Swift 側で増えない形で持つ。**
  - チャットの本文: 配送用のバッファを持たない。本文は既に Swift 側の集約（`CodexChatTurnAccumulator`）にあるので、
    メッセージごとに「送信済みの位置」だけを覚え、次の送信でその位置から後ろを送る。
  - 文字起こしの確定行: 未送信を 300 件または 256 KB まで持つ。どちらかを超えたら捨てて「再同期が必要」に切り替える。
    pipeline の UI キューと同じ規則である。
  - preview と状態表示: 最新の 1 件だけを持つ。
- Web 側は受け取った差分を `requestAnimationFrame` 単位でまとめて描画する。描画の間引きはここ 1 箇所だけになる。
- **同じ ID の行が重なったときの順序。** Web 側の規則は 2 つだけにする。
  - 実況で届いた更新（`append`、`patch`）は、常に既存の行を上書きする。
  - SQLite から読んだページは、まだ無い行だけを追加し、既にある行は上書きしない。
  - これで、ページ読み込み中に届いた新しい翻訳を、後から返った古いページが消すことは無い。`TranscriptStore` の
    `projectionRevision` による merge 規則と同じ保証を、条件分岐なしで満たす。実況の更新を取りこぼした場合は再同期になる。
- **回復。** 表示中に `presented(seq)` が 2 秒返らないか、WebContent プロセスが落ちたら、再読み込みして `reset` し直す。
  表示は再生成可能な projection なので、失うものは無い。再読み込み中は表示面に進行状態を出す。
  - 文字起こし: pipeline の flush 完了後に SQLite から読む（現在の再読み込みと同じ手順）。
  - チャット: 保存済みの履歴は SQLite から読む。生成途中の本文、推論、tool の状態、承認待ちは SQLite に無いので、
    `PiChatService.attach`（`Services/PiChatService+Subscriptions.swift:113`）で再接続し、その再生内容を送る。
- 起動時に 1 枚を先に温めておき、最初の表示で待たせない。
- 入力欄、モデル選択、スラッシュコマンド候補はネイティブのまま残す。
- 書体と配色は `DahliaTypography.baseSize` と外観設定を CSS 変数として渡す。

この柱で削除できるもの: `CodexChatMarkdownParser`、`…BlockRenderer`、`…Renderer`、`…Cache`、`…ProjectionModel`、`…TextView`、`…TableDocument`、
`CodexChatStreamingUpdateLimiter`、`SelectableTextView`、`SelectableTextContent`、`SharedSelectionLayoutManager`、`TextSelectionGroup`、
`TranscriptStore` のページ読み込み状態機械と preview の間引き。対応するテストは Web 側のテストと橋渡しのテストに置き換える。

Web にしない画面:

- **サイドバー**: 選択、コンテキストメニュー、名前変更、フォーカスがネイティブの強み。行は軽いので `List` のまま直す。
- **スクリーンショット一覧**: `NSCollectionView` は適切。遅いのは画像の供給経路で、Web にしても同じ I/O を通る。
- **ライブ字幕**: 透過の floating panel に 5 行。WebView は過剰。

### 柱 4: 非同期処理の規則を 4 つに絞る

1. `async` は isolation を越えて実際に待つ処理にだけ付ける。DB、ファイル、ネットワーク、入力サイズに比例する解析が該当する。
2. 古い結果の破棄は、次の 2 つだけで行う。世代カウンタは、Task を持たない callback 境界（音声 runtime の lifecycle など）にだけ残す。
   - 要求は対象ごとに 1 つの所有 Task で行い、新しい要求で前の Task を取り消す（`.task(id:)` か、保持した Task の差し替え）。
   - 取消しは協調的で、待ちから戻った処理を自動では止めない。`await` から戻ったら、結果を状態へ書く前に必ず
     `Task.isCancelled` と対象の identity（Meeting ID、Workspace ID、検索条件）を確認する。
   - 現在の「取消し + 世代 + identity + 追加条件」の多重確認は、この 2 つに置き換える。
     `TranscriptPageLoader.load` のように取消しを確認しない読み取りは、GRDB の非同期読み取りに置き換える。
3. 更新頻度の制御は、1 つの流れにつき 1 箇所。発生源に最も近い所に置く。
4. レイアウトの完了を時間で待たない。`Task.yield` や数十 ms の `Task.sleep` で次の描画を待つコードを書かない。

CI で守らせる（`scripts/lint.sh` に追加）:

- 許可リスト外の `Task.detached` を禁止する。所有された長寿命 worker 5〜6 箇所だけを許可する。
- `@MainActor` の型から同期の `read` / `write` を呼ぶことを禁止する。柱 1 の型分けで大半は書けなくなる。

### 柱 5: 計測を先に作る

現在、UI のハングを検出する仕組みが無い。signpost 5 箇所はすべて UI 以外で、MetricKit も使っていない。

- **MainActor 監視**: 別スレッドから MainActor へ定期的に応答を求め、50 ms 以上返らなければ長さと区間名を OSLog に記録する。
  内容や識別子は記録しない。
- **Sentry への送信**（承認済み）: 250 ms 以上の停止だけを、`ErrorReportingService` 経由で送る。送るのは停止時の MainActor のスタックと、
  次の固定タグだけ。会議名、本文、件数、正確な時間は送らない。
  - `source=mainActorHang`
  - `hangSurface`: `sidebar` / `screenshots` / `transcript` / `liveSubtitle` / `chat` / `other`
  - `hangDuration`: `250ms` / `500ms` / `1s` / `2s` / `5sPlus`
  - `recording`: `active` / `idle`
  - 同じ `hangSurface` と `hangDuration` の組は、1 回の起動につき 1 度だけ送る。送信の完了は待たない。
  - `hangProcess`: `app`（MainActor の停止）/ `web`（表示中の ContentSurface で `presented` が 2 秒返らない、または WebContent の終了）
  - 実装より先に、`docs/telemetry.md` の許可表と `docs/spec/desktop/telemetry.md` にこのタグを追加する。
  - Sentry SDK 自体の app hang 検出は、送る内容を制御できないため使わない。既定で有効な場合は明示的に無効にする。
- **区間の signpost**: 5 画面のスクロール、差分の適用、画像の供給に `OSSignposter` を置く。
- **表示までの時間**: Swift は「イベントを受け取った時刻」から、その更新を含む送信の `presented(seq)`（柱 3）までを
  signpost の区間として記録する。MainActor が動いていても WebContent だけが止まる場合は、この値と 2 秒の打ち切りで検出する。
- **再現用データ**: 開発 profile に、Meeting 500 件、1 Meeting あたり確定 5000 segment、スクリーンショット 500 枚、50 KB の Markdown 応答の再生を作るスクリプト。
- **シナリオ実行**: `run-dev.sh` で起動したアプリに対して `xctrace`（Hangs、Time Profiler、SwiftUI）を記録するスクリプト。
  負荷条件は「録音中 + 索引の再構築中 + 同期中」に固定する。

## 3. 画面別の作業

### サイドバーの過去ミーティング一覧（ネイティブのまま）

- 行のフレーム追跡をやめる。hover card の位置は、hover した行だけが取得する。
- マーキーは hover 中の行だけが組み立てる。それ以外は素の `Text`。
- 一覧の入力を 1 つの不変な値（グループ化とソート済み）にする。DB 読み取りの中で作り、MainActor では代入だけを行う。
  現在は MainActor で 6 箇所が全件を再グループ化し、body 内でプロジェクトを毎回ソートしている。
- 行は値だけを受け取る `Equatable` な View にする。`RecordingModel` から必要な 4 値だけを渡す。
- 別プロセス（`dahlia-mcp` など）の書き込み通知（`SidebarViewModel.swift:312-336`）は残す。`DatabasePool` にしても、
  別プロセスの commit は `ValueObservation` に届かないため、通知を受けて読み直す必要がある。
  変えるのは読み直し方で、一覧を 50 件に戻さず、読み込み済みの件数のまま取得し直す。スクロール位置と選択は保つ。
- 予算を満たさない場合だけ `NSTableView` に置き換える。

### スクリーンショット一覧（`NSCollectionView` のまま、画像の供給経路を作り直す）

- 取得時に 400 px のサムネイルをディスクへ書く。`ScreenshotFileStore.write` は `.thumbnail` に対応済み。既存の画像は初回表示時に作る。
- cache の鍵を `(id, contentHash, 画素数)` にし、原本を読む前に引く。原本バイトの保持と全バイト比較を削除する。入れ物は `NSCache`。
- サムネイルの読み取りは actor の直列から外し、並列 4 で読む。サムネイルは再生成できるので、digest 検証とアクセス時刻の書き込みを行わない。
  原本の検証は、要約・同期・書き出しの経路にそのまま残す。
- 上記で直列 worker が無くなるので、lane 分離、`ScreenshotImageDecodeWorker`、single-flight と waiter 管理、三重の世代確認を削除する。
- `NSCollectionViewPrefetching` で 1〜2 行先を読む。
- ヘッダーの再計測は、幅か内容が変わったときだけ行う（`ScreenshotCollectionLayout.swift:27-36`）。

### 文字起こし（ContentSurface）

- 行の表示、選択、スクロール位置、追記への追従を Web 側に任せる。録音中も選択できるようにする。
- Swift 側は、SQLite からの keyset ページ読み取りと、pipeline から届く確定・preview の転送だけを持つ。
- `TranscriptionEventPipeline` の UI 側キュー（latest-wins、300 件で再読み込みへ圧縮）は変更しない。
- 履歴を見ている間は新着を挿入せず、末尾への案内を出す（[Transcript projection](../spec/desktop/concurrency-and-projection.md#transcript-projection) の契約を維持）。

### ライブ字幕（ネイティブのまま、最新 N 行だけ）

- 最新 1〜5 件だけを単純な `VStack` で表示する。パネルの高さは `fittingSize` を 1 回測って決める。
- 履歴スクロール（#366）は廃止する。履歴は文字起こしタブで見られる。
- `LiveSubtitleOverlayPayloadProjector`、`EntryCollection`、計測用の 2 枚目の `NSHostingView`、`Task.yield` 後の再計測、二重の末尾追従を削除する。
- `LiveCaptionStore` は確定分を末尾 N 件に切り詰める。
- relay（認識側を MainActor から切る）と 200 ms の公開間隔は残す。

### AI チャット（ContentSurface）

- 会話の表示（本文、表、コード、承認、tool の記録、関連スレッド）を Web 側で描画する。`AiChat.tsx` の部品を使う。
- Swift 側は、本文の「送信済みの位置」から後ろを `streamDelta` で渡す（柱 3）。解析と描画の間引きは Web 側で行う。
- `PiChatService` の所有、256 件の購読バッファ、保存履歴からの再接続は変更しない。
- 表のコピーを TSV にする現在の挙動は、Web 側の copy イベントで維持する。

## 4. 進め方

各段階は独立した変更として出し、段階ごとに予算を測る。

| 段階 | 内容 | 終了条件 |
| --- | --- | --- |
| P0 計測 | 柱 5。テレメトリ方針の更新を含む。現状の基準値を 5 画面で記録する | 基準値がこの文書に追記されている |
| P1 データベース | 柱 1。MainActor 上の同期 DB 呼び出しを無くす。再構築の commit をまとめる | 再構築中でも画面の読み取りが 50 ms 以内に返る |
| P2 状態 | 柱 2 | `CaptionViewModel` を購読する View が 0 |
| P3 ネイティブ 3 画面 | サイドバー、スクリーンショット、ライブ字幕 | 下の予算を満たす |
| P4 ContentSurface | 先に AI チャットで試作し、予算を測ってから文字起こしへ進む | 下の予算を満たす。WebContent の停止と終了からの回復試験が通る。旧実装を削除済み |
| P5 規約 | 柱 4 の lint。ARCHITECTURE の Conformance 表、`docs/spec/`、`test-responsiveness.sh` を現状に合わせる | lint が CI で動く |

P1 と P2 は互いに独立で、P4 の試作は P0 の後なら並行で始められる。P3 は P1 と P2 の後に行う（先に行うと、原因 A と B の影響で効果を測れない）。

### 予算（負荷条件: 録音中 + 索引の再構築中 + 同期中、再現用データ）

| 指標 | 目標 | 挑戦目標 |
| --- | --- | --- |
| MainActor が 250 ms 以上止まる回数（5 画面の操作 各 60 秒） | 0 | 50 ms 以上が 0 |
| 確定文字起こしが画面に出るまで（p95） | 150 ms | 50 ms |
| チャットの delta が画面に出るまで（p95） | 100 ms | 33 ms |
| スクリーンショットを戻りスクロールしたときのファイル読み取り | 0 回 | — |
| サムネイルの初回表示（p95） | 50 ms | 16 ms |
| 録音の音声フレーム欠落、確定文字起こしの欠落 | 0（現状維持） | — |

判定は MainActor 監視のログと `xctrace` の Hangs 記録で行う。文字起こしとチャットの表示時間は、柱 5 の `presented(seq)` までの区間で測る。
目視や自己評価では判定しない。現状の値は未計測なので、P0 の結果で目標値を見直す。

ContentSurface の回復試験（P4 の終了条件）:

- Web 側を意図的に止めた状態（開発ビルドだけの停止用メッセージ）で delta と確定行を流し続ける。停止は 2 通りで試す:
  JavaScript の呼び出しが戻らない場合と、呼び出しは戻るが描画されない場合。
- どちらでも、Swift 側の未送信が上限（300 件または 256 KB）を超えず、2 秒で再読み込みに入る。
- 回復後、文字起こしは SQLite の内容と一致する。生成中のチャットは、途中の本文と承認待ちが表示され、承認を操作できる。
- WebContent プロセスの終了通知を受けたときも、同じく回復する。
- ページ読み込み中に翻訳の更新を流し、古いページが返った後も新しい翻訳が表示されている。
- どちらの間も、録音の音声受付と確定文字起こしの保存が進む。

### 基準値（2026-11-20、P0 時点のコード）

計測: `apps/macos/scripts/seed-responsiveness-fixture.sh` の合成データ（Meeting 500、確定 5000 行、スクリーンショット 500 枚）と、
`run-dev.sh --copy-production` の実データ。`apps/macos/scripts/responsiveness/ax-driver.swift` がアクセシビリティ API でスクロールバーを
端から端まで動かし（200 段階、30 ms 間隔）、`MainActorHangMonitor` の OSLog から 50 ms 以上の停止を数えた。録音はしていない。
ウィンドウは他のアプリの裏にあったため、描画まで含めた値ではない可能性がある。

| 操作 | 50 ms 以上の停止 | 中央値 | 最長 | 停止の合計 |
| --- | --- | --- | --- | --- |
| サイドバー 2 往復（合成 500 件） | 5 回 | 129 ms | 245 ms | — |
| サイドバー 2 往復（実データ） | 2 回 | 59 ms | 77 ms | 136 ms |
| 文字起こし 2 往復（合成 5000 行、51 秒） | 106 回 | 165 ms | 489 ms | 18.5 秒 |
| 文字起こし 2 往復（再計測、54 秒） | 114 回 | 157 ms | 676 ms | 20.3 秒 |
| スクリーンショット 1 往復目（未読込） | 3 回 | 102 ms | 192 ms | 395 ms |
| スクリーンショット 2 往復目（cache あり） | 0 回 | — | — | — |
| 保存済みチャットを開く（実データ） | 0 回 | — | — | — |

- 文字起こしのスクロールが突出して悪い。操作時間の 3 分の 1 以上、MainActor が止まっている。
- スクリーンショット一覧の MainActor は軽い。サムネイルが出るまでの時間は、この計測の後に記録を追加した（`latency surface=screenshots`）。
- チャットのストリーミングは、開発 profile の Databricks サインインが期限切れで測れなかった。再サインイン後に測る。
- ライブ字幕とライブ文字起こしは録音が必要なので測っていない。

### 途中経過（2026-11-20）

実装済み:

- P0: `MainActorHangMonitor`（停止の OSLog と Sentry 送信、画面の印、反映時間の記録）、合成データの投入スクリプト、`ax-driver`。
- P1: 主 DB を `DatabasePool` にし、検索専用の接続を削除した。接続ごとの一時テーブルにある transfer fence の確認は書き込み接続へ移した。起動時の VACUUM は barrier で実行する。
  `createEmptyMeeting` と `materializeDraftMeeting` の同期書き込みは残っている（呼び出し元 14 箇所が戻り値を同期で使う）。
- P4（文字起こし）: `TranscriptWebSurface` と `packages/ui/src/content-surface/transcript.ts`。React は使わず依存の追加はない。
  旧 `TranscriptRowView` と `TranscriptRowTextView` を削除した。
- P3（一部）: サイドバー行のフレームを状態から外し、マーキーを hover 中の行だけにした。サムネイルは content hash を鍵に、原本を読む前に cache を引く。

同じ合成データ・同じ操作での比較（基準値の表と同じ計測方法）:

| 操作 | 基準値 | 現在 |
| --- | --- | --- |
| 文字起こし 2 往復 | 106〜114 回、最長 489〜676 ms、合計 18〜20 秒 | 1 回（84〜94 ms）。更新の反映 p95 10 ms |
| 実データの文字起こし（563 行）2 往復 | — | 1 回（52 ms）。反映 p95 12 ms |
| サイドバー 2 往復（合成 500 件） | 5 回、最長 245 ms | 6 回、最長 318 ms（改善なし） |
| スクリーンショット | 1 往復目 3 回、最長 192 ms | 1 往復目 1 回（205 ms）。サムネイル表示 p95 48 ms |

- サイドバー: サンプリングでは、行を作る時間の半分が `List` の行ごとの `NSHostingView` で起きるアクセシビリティの更新、
  残りが全行のフレーム追跡（`AnimatableFrameAttribute`）と hover 応答だった。フレーム追跡を hover 中の行だけにし、
  行ごとの `@AppStorage` を環境値に変えた結果、ページを読み込みながらの 2 往復は 6 回（最長 318 ms、合計 1.1 秒）から
  2 回（最長 127 ms、合計 0.19 秒）、読み込み後の 2 往復は 5 回（最長 200 ms）から 3 回（最長 174 ms）になった。
  250 ms 以上が 0 回で予算内なので、`NSTableView` には置き換えない（予定・Project の開閉・複数選択・名前変更などの作り直しが大きく、バグの危険に見合わない）。
  注意: アクセシビリティ API で計測すると、SwiftUI のアクセシビリティ更新も計測値に含まれる。アクセシビリティを使うアプリが動いている Mac では実際の操作でも同じ負荷がかかる。
- サムネイルは 2 往復目も表示まで 30 ms かかる。500 枚分が cache の上限 32 MB に収まらず、毎回読み直している。ディスクのサムネイルで読み込み自体を軽くする。
- P3（ライブ字幕）: 最新 1〜5 件だけを表示する `VStack` にした。差分 projector、参照型のコレクション、計測用の 2 枚目の `NSHostingView`、
  `Task.yield` 後の再計測、末尾追従を削除した。録音が必要なので実測はしていない。

- AI チャット: 実モデルの認証ができなかったため、実際の会話ビュー（`CodexChatConversationView`）に 50 KB の Markdown を 20 Hz で
  流し込むベンチマーク（`ResponsivenessChatStreamingBenchmark`、`DAHLIA_RESPONSIVENESS_BENCHMARK=1` のときだけ動く）で測った。
  過去の長い応答 6 件がある会話では、25 秒の流し込みに 145 秒かかり、50 ms 以上の停止が 389 回（最長 1.5 秒、合計 115 秒）あった。
  原因は、SwiftUI が 1 回のレイアウト中に幅 0・32・167.5・688 などで高さを問い合わせるたびに、`CodexChatSelectableTextView` が
  レイアウトを捨てて組版をやり直していたこと（計測中 30 万回）。問い合わせの幅には推定値を返し、レイアウトは実際に置かれた幅
  （`setFrameSize`）でだけ行うようにした結果、37.5 秒、停止 2 回（いずれも開いた直後の初回レイアウト、577 ms と 412 ms）、
  ストリーミング中の停止 0 回になった。1 更新のレイアウトは中央値 36 ms から 13 ms。
  チャットの WebView 化は行わない。原因は表示の仕組みではなく 1 箇所の不具合で、会話の部品（89 ファイル、承認・ツール記録・添付を含む）を
  作り直す危険に見合わない。開いた直後の初回レイアウト（極端に長い応答が並ぶ場合に約 1 秒）は残っている。

- サムネイル: ローカルの原本でも、一覧で初めて表示したときに `thumb_480`（JPEG）を作って保存し、2回目以降はそれを読む。
  WebP の符号化は 480px で1枚約 100 ms かかり、直列の content provider で要求が滞留して p95 が 4〜7 秒になったため JPEG にした（1 ms 未満）。
  スクロールで外れたセルの要求は入口で取り消し、ローカルの読み込みでは削除順のための最終アクセス時刻を書かない（ローカルは削除対象外）。
  結果は 1 往復目 中央値 46 ms・p95 62 ms（変更前 31 / 48 ms）、2 往復目以降 中央値 16 ms・p95 19 ms（変更前 30 / 44 ms）。
  契約は [同期の仕様](../spec/shared/sync.md#画像の-variant-と保存形式) に書いた。
  続けて、1件あたりの dahlia.sqlite の読み取りを6回から2回（読み込み前のまとめた1回と読み込み後の再確認1回）にし、
  メモリ cache を decode 済み画像（約60枚）から符号化済みのバイト列（500枚で 13.7 MB）にし、decode の直列 lane を並列にした。
  検索結果のタイルも content hash で同じ cache を引き、当たれば取得を省く。ローカルの控えは `thumb_480.jpg` という名前にした。
  2往復目は 中央値 14 ms・p95 17 ms。残りはスクロール中のメインスレッドへ戻る時間で、読み込み側では縮まらない。
- サイドバーと Project 詳細の追加ページは、`Task.detached` と手書きの取り消しをやめ、`DatabasePool` の非同期読み取りにした（取り消すと実行中の文も中断する）。
- `Task.detached` は lint（`apps/macos/scripts/task-detached-allowlist.txt`）でファイルごとの件数を上限にし、増えたら CI が失敗する。

行わないと決めたもの:

- `createEmptyMeeting` と `materializeDraftMeeting` の非同期化。`DatabasePool` で待つのは実行中の書き込み1件だけになった。呼び出し元14箇所が同期で受け取る ID と、失敗時の巻き戻しの作り直しに見合わない。
- P2（`CaptionViewModel` の分割）。頻繁に変わる値（音量、経過時間、文字起こし、字幕）は既に別の store にあり、ノート本文は画面から書き換えられていない。分割の効果を示す計測結果がない。
- `TranscriptStore` の preview の間引きとページ要求の二重ガードの整理。害がなく、外すとページ読み込みのテストを作り直すことになる。

計測の注意: `ax-driver` の `press` と `select-row` はアクセシビリティの木を全行たどるので、`NSTableView` が全行の表示を作り、その間の停止は計測の影響になる。停止の計測には `scroll`（最初に1回だけスクロールバーを探す）だけを使う。

この計画で残っているのは、ライブ字幕とライブ文字起こしの実機計測（録音が必要）と、計測結果を仕様へ移して計画を閉じることだけ。

## 5. 承認済みの判断（2026-11-20）

| 判断 | 内容 | 記録先と時期 |
| --- | --- | --- |
| ContentSurface の採用 | AI チャットと文字起こしを WebView に移す。React と react-markdown を macOS アプリに同梱する（現在の同梱物には含まれていない）。同梱する版は `packages/ui` の指定に合わせ、ライセンス一覧を生成する | `docs/spec/desktop/concurrency-and-projection.md`。文字起こしは実装済み。チャットは計測の結果、WebView 化しないことにした |
| 描画の別プロセス化 | ARCHITECTURE の保証範囲に「ContentSurface の描画停止はアプリの MainActor を止めない」を加える。録音の helper process は引き続き対象外 | ARCHITECTURE の Conformance 表。文字起こしについて反映済み |
| `DatabasePool` への切り替え | 起動時に WAL へ切り替えられない場合は、現在と同じく起動を優先して 1 本の接続で動かし、次回起動で再試行する（`AppDatabaseManager.swift:53-58` の挙動を維持） | ARCHITECTURE。反映済み |
| ライブ字幕の履歴スクロールの廃止 | 最新 1〜5 行だけを表示する。設定画面と文言から履歴に関する記述を除く | `ARCHITECTURE.md` の Conformance 表。P3 |
| ハングの Sentry 送信 | 柱 5 の固定タグだけを送る | `docs/telemetry.md` と公開プライバシーポリシー。反映済み |

契約は `docs/spec/` に、現在の構成と適合状況は ARCHITECTURE に書く。この計画が終わったら、残る未解決事項を仕様へ移して計画を削除する。

## 6. 採らない案

- **文字起こしを `NSTableView` に、チャットを TextKit 2 の単一 `NSTextView` にする。** ネイティブの操作感は保てる。
  ただし描画はアプリの MainActor に残り、表・コード・承認 UI を TextKit の中に作り込むことになり、Web 版との二重実装も残る。
  P4 の試作が予算を満たさなかった場合の代替とする。
- **メッセージ行ごとに WebView を置く。** プロセス数と高さ同期のコストが大きい。会話全体で 1 枚にする。
- **サイドバー、スクリーンショット一覧、ライブ字幕の Web 化。** 上記の理由で利点が無い。
- **録音の helper process 化。** 録音経路が止まった証拠は無い。必要になったら保証範囲の変更として判断する。
- **全画面共通の scheduler や worker の新設。** 優先度の逆転と lifecycle を増やす（[却下した案](../spec/desktop/concurrency-and-projection.md#却下した案)）。

## 7. 未確認の事項と、確認する段階

| 事項 | 確認する段階 |
| --- | --- |
| 5 画面の現状の停止時間。画面別の主因はコード読解によるもので、実測は無い | P0 |
| 現行 v1.9.0 での索引再構築の書き込み量。診断レポート 2 件は v1.0.2 と v1.3.0 のもので、ハングそのものの記録はこの Mac に残っていなかった | P0 |
| Sentry SDK の app hang 検出が既定で有効か（`Services/ErrorReportingService.swift:106-116` は関連 option を設定していない） | P0 |
| `ValueObservation` を取り消した後に、配送済みの callback が届かないことを GRDB が保証するか | P1 |
| `DatabasePool` と、同じファイルを開く `dahlia-mcp` など別プロセスとの共存 | P1 |
| WebContent プロセス 1 つあたりのメモリ量と、複数の ContentSurface がプロセスを共有するか | P4 の試作 |
| `reset` の引数の直列化が MainActor を使う時間（ページ単位で送る前提） | P4 の試作 |
| WebView 内の VoiceOver、検索（⌘F）、ネイティブ入力欄とのフォーカス移動 | P4 の試作 |

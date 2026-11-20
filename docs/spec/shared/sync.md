# Desktop / Server の canonical sync

対象: Desktop・Server・Private Web。採択: 2026-09-02〜09-03。送信の優先度と Server のロック分割は 2026-09-30、更新単位のロックは 2026-10-02 にユーザーが承認した。API の詳細は [Server README](../../../apps/server/README.md)、ローカルの保存保証は [Architecture](../../../ARCHITECTURE.md) を参照する。

## 正本とアカウント境界

Server account の Workspace / Project / meeting は Desktop と Web が共有する Server canonical record とし、Desktop の既存 SQLite 行を offline working copy にする。Local Account は独立して動作し、sync transaction を作らない。録音と確定文字起こしの保存はネットワークを待たない。

- サインインだけでは Local Workspace を移さない。移行画面で Organization を選び独立した ID の Server Workspace を作るか、Admin／Editor 権限のある既存 Workspace へ内容を取り込む。バックアップ、snapshot の ID 衝突検査、接続・権限・録音・pending sync の検査後に確定する。Local Workspace 自体の ID・所属は変更しない。詳細は [取り込み](organization-personal-workspaces.md#同期と移行) と [Workspace 再接続](../desktop/workspace-reconnection.md) に従う。
- サインアウト前に local working copy を削除するか Local Account へ移す。どちらも Server record は残す。Local Account への移動では metadata 同期を完了し、全本文と不足する画像原本を先に揃え、ファイル参照の保存と queue、confirmed revision、cursor、接続関連の解除を同じ SQLite transaction で確定する。取得失敗時は接続と未送信データを保持する。
- export folder は任意の端末固有設定で、同期しない。未設定でも SQLite と同期データは利用でき、Markdown export / filesystem watch だけを無効にする。

## Server Workspace の自動発見

Desktop は `GET /api/v1/workspaces` で全 principal からアクセスできる Admin／Editor／Viewer の Workspace を発見する。metadata を同期し、本文・画像は必要時に取得する。`organizationId` は所有 Organization で絞り、owner query は提供しない。Web は Organization context を持たず、権限のあるすべての Workspace を既定で表示する。Organization による絞り込みは必要になった時点で Workspace 一覧へ追加する。

登録は接続を再検査する SQLite transaction で冪等に行い、確定 revision と作業コピーを同時に保存する。登録による upload は作らない。Server 所属 Workspace は常に利用可能として表示し、Desktop の Workspace 削除操作によるローカル登録解除は提供しない。Local Account の Workspace 削除とサインアウト時のデータ処理は維持する。同一 ID の Local Workspace や別接続の Workspace は自動移行しない。既存の同期待ち操作、cursor、最終選択は維持する。通信失敗や一覧からの欠落だけでは削除せず、権限失効は既存の同期・データ保全経路で処理する。サインイン操作から Local Workspace の移行確認は出さず、明示移行操作を使う。

## 同期対象とモデル

同期するもの: Workspace 名・アイコン・色、2段階 Project 階層と名前・説明・アイコン・色、meeting metadata、meeting のカレンダー情報（下記）、summary document、transcript 原文、screenshot bytes / MIME / OCR / AI caption。新規バッチ録音の結合音声は [専用の音声保管契約](recording-audio-archive.md) で扱う。会議 Notes はこの同期契約に含めず、[Documents 専用同期](#documents-専用同期) で扱う。

同期しないもの: 翻訳文、SQLite ファイル、端末の export path、端末内 note、tag、音声特徴量。

### カレンダー情報

meeting の `icalUid` / `recurrenceId` と `calendarEvent`（`start` / `end` / `is_all_day` / `attendees`）を同期する。UID と recurrence ID はペアで扱い、単発予定の recurrence ID は空文字。`attendees` の省略は既存値維持、空配列は参加者の消去、`calendarEvent: null` はスナップショット全体の消去とする。予定名・説明・URL と端末固有のカレンダー参照は同期しない。暗号化 Workspace では `calendarEvent` 全体を暗号化し DB 列をマスクする。Server の開始・終了・終日フラグは要約の XML context と入力変更検知に使用する。

Desktop は受信した値（null を含む）を端末固有参照と別の working copy に保存し、通常更新・初期同期・復旧時の送信にはその値を使う。未受信の会議だけはローカル予定から初期化する。ローカル予定の開始・終了日時・終日フラグ・参加者が変化した場合は、書き込み可能な Server Workspace の同一予定に紐づく会議について、working copy の更新と送信キューへの記録を同じ SQLite transaction で確定する。Server で消去・別予定へ変更された識別子はローカル予定の再観測で戻さない。受信処理は送信キューを作らず、新しい未送信変更がある間は既存の receipt／delta 適用ガードを維持する。

### Project と transcript

Project は `app.projects` に置き Workspace 権限を継承する。空 Workspace と Project 単独変更も扱い、同じ Workspace の meeting だけが参照できる。Project 削除前に依存 meeting を明示的に移動・解除し、依存が残る削除を Server が拒否する。Project は階層閲覧・明示 filter に使い、検索本文や vector へ混ぜない。

transcript の収録経路は `audio_source: mic | system`、人・diarization の話者は nullable `speaker_label` として分離する。Desktop の収録経路は forward migration で移し、話者欄を空にした。Server の旧 field との互換経路は持たない。

Transcript UUID は生成元で確保して再送でも維持する。Server は `meeting_id` で meeting を参照し `(meeting_id, version)` を一意とする。`workspace_id` は重複保持せず、子 segment の権限も meeting 経由で判定する。生成開始・終了確認は親の `started_at` / `ended_at`、初回 Server 保存は親の `created_at` とする。子の `started_at` / `ended_at` は発話の絶対日時、`created_at` は確定テキストを生成した日時とする。子は確定テキストだけを保存する。

`status` は親の終了確認と子の作成日時から読み取り時に導出し、同期状態や録音状態と区別する。時刻だけでも変化するため同期 revision を増やさず、Web の期限タイマーと読み取り側の再計算で更新する。定義・既存 Desktop データの補完方針は [Audio and Transcription Data Flow](../../architecture/audio-transcription-data-flow.md#transcript-versions) に従う。

### Summary 世代と同期番号

Server の要約正本は `summaries` の最大 `version` とし、meeting に本文や最新ポインタを重複保存しない。世代は Workspace lock 下で発番し、同期の `summary_revision` / `baseRevision` とは独立する。latest の通信形式は `formatVersion`、世代は `version`、同期番号は `revision`。同期 entity ID は meeting ID のまま維持する。全履歴削除後は version を1から再開するが、同期 revision は継続する。receipt、競合応答、削除通知、Desktop の未送信編集保護と本文 hash 検証は維持する。

### 外観

Project / Workspace の `icon`・`color` は nullable な正準フィールドとし、ProjectIcon / ProjectThemeColor の保存値を使う。transaction で未指定の項目は保持し、null は設定解除。外観変更も通常の revision・競合検出・snapshot / delta の対象にする。Web と Desktop の編集 UI は同じフィールドを使い、子 Project は親の外観を継承する。子の独自外観は送信・保存せず、親から子への変更時には解除する。`appearance` JSON 列は持たない。

Desktop の旧 `projectAppearances` UserDefaults は Workspace を開いたときに DB へ移行する。Server 接続では確認済み Admin／Editor の未設定 Project にだけ通常の transaction を記録し、未送信操作や競合を上書きしない。旧設定はローカル保存または送信確認まで保持する。Desktop 専用の `legacyAppearanceMigrated` は再移行を防ぐ印であり同期しない。競合解決で正本の未設定値を選んだ場合にも、旧設定を再適用しない。

### 生成設定と言語設定

認識対象の `analysisLanguages` は個人設定として Server DB を正本とし、Desktop は接続・認証 user ID に束縛したメモリで保持する。初回 GET が未作成なら端末の現在値で conditional INSERT し、他端末の初期化を上書きしない。`account_settings` SSE invalidation と再接続で再取得する。

Desktop のモデル・推論強度・スタイル・録音後の処理・ライブ下書きの保存先と引き継ぎは [アカウント別 Desktop 推論](account-scoped-desktop-inference.md) に従う。Web の Server 処理設定は [処理場所と設定](transcription-summary-processing.md) に従い、Workspace の `generationSettings` は既存の管理者による update transaction・baseRevision・receipt / delta / snapshot / SSE を通す。Desktop と Web で共有する Workspace の既定値は出力言語のみとする。

開始済みの処理は開始時に固定した設定を再試行でも保持する。既知の古い文字起こしはローカル要約の開始前に正本を取得する。手動生成で「保存済みの文字起こしを使う」を選択した場合のみ取得を省略し、古い版を使う可能性を確認画面に明示する。

設定取得と認証更新は録音開始・継続・停止の前提にしない。既存 working copy は設定未取得・期限切れ認証でもローカル録音と文字起こしを継続し、音声・確定文字起こし・画像・同期待ち操作を既存経路で保持する。再認証が必要なら同期だけを待機させる。新規サインインのオフライン対応は対象外。

## Capabilities と互換性

`GET /api/v1/capabilities` は機能別の対応 version を返す。`sync` の version は7。ほかの機能の version は、その機能を定める節または仕様に書く（会議イベント、画像解析は下記、Documents は [Documents](documents.md)）。entity revision や payload schema の version とは区別する。非対応の機能はフィールドを省略し、atomic sync 非対応の store は全機能を省いた `200 {}` を返す。認証・運用エラーは通常のエラーとして返す。クライアントは未知のフィールドを無視する。

現在の同期契約は `sync.version = 7` で表す。transaction は schemaVersion 3 を使う。

- Desktop は `sync` の version を確認する。非対応では `updateRequired` を表示し、既存本文を保持して同期・解放を止める。受信は60秒ごとに capability を再確認し、Server の更新後は再起動なしで再開する。
- 契約を変えるときは互換経路・fallback を残さず、Server / Web、次に Desktop の順で同じリリースとして切り替える。旧契約の相手とは同期せず更新要求にする。契約が異なる開発版同士も更新要求になる。
- 旧フィールドと旧ルートは維持しない。

## Transaction と競合

- `POST /api/v1/transactions` は1 Workspace の operation 群を atomic commit する。transaction schemaVersion 3 を要求する。UUIDv7 transaction ID を冪等キーとし、commit response を保存する。同じ ID と異なる内容の再利用は拒否する。
- Workspace、Project、meeting metadata、summary は optimistic revision を使う。古い base revision は対象 entity と canonical record を含む `409` とし、暗黙の last-write-wins をしない。
- Desktop は local record と retry 用 snapshot を同じ SQLite transaction に書く。操作の schema は `sync_transactions`（順序・lease・retry・block）、`sync_operations`（immutable JSON と独立した画像ファイル参照）、`sync_entity_state`（Server-confirmed revision のみ）、`sync_transcript_patch_items`（upsert / delete）で管理する。本文の保持状態は別の `sync_content_state` に保存し、expected / optimistic revision や pending/running の派生状態を重複保存しない。
- transcript patch と画像は bounded staging endpoint へ送り、その後に元の domain transaction を commit する。staging だけでは read surface に公開しない。全段階で現在の Workspace 権限、ID、親子関係、hash、payload limit を検証する。
- local mutation は recorder を明示的に呼び、remote applier は呼ばない。receipt 反映時は新しい optimistic operation を上書きせず、confirmed revision と commit cursor の保存後に acknowledge 済み transaction を削除する。
- validation、revision conflict、authorization、transport failure は別状態で永続化する。自動 retry は transport error、408、425、429、5xx のみ。
- blocked transaction は、それに依存する後続だけを止める。競合解決の対象は blocked transaction とそれに依存する後続に限る。lease 中・応答不明の transaction は、元 ID の結果を確定するまで破棄・再登録しない。

### 競合採用後の対象単位の再取得

既存の pull cursor があり Workspace 自体を含まない競合・validation を破棄する場合、対象 entity を永続的な再取得リストへ記録する。cursor と無関係な entity の revision は保持する。通常差分で対象が届けば同じ revision でも採用し、届かなければ snapshot から対象だけを再取得する。この処理は Workspace 全体の snapshot 復旧とは分離し、無関係な blocked transaction を待たない。取得中の mutation generation 変更、新しい対象編集、録音・移管・接続変更は既存の受信ガードで再検査する。再取得リストの消去は本文・metadata の適用と同じ DB transaction で行う。Workspace 全体の reset・初期同期・cursor 失効の厳しい復旧条件は維持する。

再取得リストは migration `v52_documentsAndSync` で作成する。配布済みの v47（録音復旧）までの migration の登録・処理は変えない。ローカルで削除した親を Server 版へ戻す場合は、canonical な子と参照ファイルも復元する。親の通常差分が先に到着しても、子の列挙を永続化するまでは再取得リストを残す。接続解除・Workspace 移動・キューの全破棄では対応するリストも破棄する。

### ファイル単位の validation 破棄

`422 file_content_missing` で原子的に拒否された単独 file 操作は、該当ファイルとその meeting_attachment 操作だけを破棄できる。未送信の紐付けバッチに他のファイルが含まれる場合は、それらの operation、base revision、原本参照、順序を保ち、新しい request ID で継続する。送信中・結果不明・別の blocked request を書き換えず、確認後にキューが増えた場合も再確認を求める。既存 pull cursor を維持し、破棄対象のみ canonical 再取得リストに登録する。対象 file／紐付けの初期構築が未完了の場合や pull cursor がない場合は、ファイル単位の破棄を提示しない。Workspace 全体の復旧条件は維持する。

確認ダイアログの件数は実際の依存関係による対象を数える。ファイル単位では、混在バッチ内の無関係な紐付けや会議本文を破棄数に含めない。初期構築前の画像解析などが未確定ファイルの最初の upsert を作る場合も、端末の原本参照を送信操作に含める。

削除済みの紐付けは、同 Workspace の確定済み関係・未送信 payload・単一操作の依存キーから関連先を復元する。混在バッチの依存キーだけでは個別操作の関連先を断定せず、特定不能な紐付けがある場合はファイル単位の破棄を提示しない。削除前の会議も確認件数に含める。

## Desktop の送信

### 優先度と順序

- 操作を通常と背景に分類し、通常4件に背景1件の実行機会を与える。Workspace 間は巡回する。最新優先は古い変更の破棄や同一 entity の逆順送信を意味しない。
- 作成・削除・所属変更に必要な依存と同一 entity の順序を永続化する。旧・新の親と Project の2階層を保護する。依存不明・backfill 前は Workspace barrier とし、必要な親操作の優先度を引き上げる。
- 依存索引、確定済みの親、構築済み entity、選択回数は SQLite に保存する。索引のない既存キューは背景扱いで32 transaction ずつ索引を補完する。
- 旧親は SQLite の `BEFORE UPDATE/DELETE` trigger で記録し、recorder が同じ transaction 内で消費する。行を変更済みの呼び出し元でも旧親を推測しない。未知の旧関係は barrier を維持する。
- キャンセルだけでは Server での未確定を証明できない。lease を解放しても試行履歴を保持し、再 claim 時に元 ID を resolve する。Server が unknown を返した場合だけ未送信として扱える。
- 初回送信は事前の resolve を省き、Server の冪等な commit を使う。再送は元の transaction を resolve してから必要な staging を行う。

### 転送枠

| 対象 | 枠 |
| --- | --- |
| 画像、文字起こしの chunk、録音 archive の共有転送 | 合計8枠、背景最大7枠。1枠を対話的な転送に残す |
| 軽い送信 | 2枠、背景最大1枠。共有転送枠とは独立 |
| 本文取得 | 2枠、背景の先読み最大1枠。待機中の明示操作を優先 |
| Notes（Documents） | 別枠 |

- 音声 archive は別タスクとし、必要な親 ACK で開始可能にする。
- file staging は共通の SyncWorker が処理する。先読みは同じ Workspace の先頭8 transaction、最大8 file operation までとし、原本の読み込みも転送枠の取得後に行う。file lookahead は file 原本を含む sendable な要求を先に絞り、先行する無関係な要約に探索枠を使わない。同じ file の後続操作、未確定の Workspace 作成・reset・削除、再送確認待ち・blocked transaction を越えて staging しない。commit / receipt 適用は Workspace 内の依存と同一 entity の順序を守る。先読みの失敗は対象 transaction の送信時に既存の retry / block 経路へ渡し、手前の commit は妨げない。
- staging 完了はメモリ内だけに保持し、5分を超えた結果は再アップロードする。再起動後は resolve / staging で再開する。キュー破棄、接続・権限・移管状態の変更、worker 停止で未完了の先読みをキャンセルし、古い結果を commit しない。
- domain commit の一つの transaction は分割しない。通常の録音停止は同期を待たない。

### 初期構築と初期 snapshot

- 初期構築は entity ごとに再開可能にし、構築済みの編集は後続として、未構築の編集は最新初期状態として記録する。Local 取り込み・復元・初期同期に共通適用する。
- 初期構築の開始時には識別情報だけを登録する。本文の構築と原本の準備は entity ごとに進め、全画像の準備完了を会議 metadata 送信の条件にしない。既に構築した要求 ID は再起動や後続編集で置換しない。
- 新規の初期構築は同 Workspace・同 entity・同優先度で最大8操作、wire envelope 込み256KiB を目安にまとめる。大きい1操作と transcript は単独で進める。親の作成順と依存を保持し、既に durable な要求 ID・payload は書き換えない。queue の既存 bulk 分割と通常操作の atomicity は維持する。
- 初期 snapshot の送信順序は Workspace / Project、全会議の metadata / summary / transcript、file、添付関連付けの順とする。全画像のアップロードを待たずに会議本文を利用できる。構築済みのキューは並べ替えない。
- worker は録音中も push / pull できるが、transcript patch は確定済み segment だけを queue に入れる。初期 snapshot は bounded SQLite write で録音へ実行機会を譲り、構築中に対象 Workspace の録音や別 mutation が始まれば未送信の部分 snapshot を捨てて最新 working copy から再構築する。
- 録音による初期同期・復旧・本文置換の待機は対象 Workspace 内だけで判定する。移動の反映では移動元と移動先を確認する。別の Local / Server Workspace の録音には依存せず、録音待ちの Workspace があっても他の Workspace の初期 snapshot 構築を続ける。
- 初期 snapshot の原本取得が失敗した場合はその Workspace のローカルデータを保持して失敗を報告し、他の Workspace の snapshot 構築・送信・受信は続ける。明示的な競合解決では呼び出し元へ取得失敗を返す。
- snapshot 復旧の pending / recovering はローカル送信キューの確定を待つため、既存の file staging を止めない。移管保留・更新必須・権限喪失など、送信できない状態とは区別する。

## 受信

受信は送信と独立させる。通常受信では接続・認可・reset・移管の世代と entity の revision / pending を再検証し、無関係な ACK で全体を中断しない。snapshot と本文 hydration の厳しい保護は維持する。

- `RemoteChangePolicy` が通常差分・依存取得・指定 revision の本文反映の適用条件を共有する。送信待ち・送信中・競合停止中の操作と、現在および要求内の親子参照を検査する。録音中の transcript、会議や参照の削除、録音画像の原本差し替えを保護する。他の会議や競合しない OCR / caption 更新は録音だけを理由に止めない。Project 階層の整合は snapshot 単位を維持する。confirmed revision は通常同期が管理する。
- 通常差分は保留があっても後続ページを読む。永続 cursor は保留のないページまでしか進めず、先読み cursor と high-water は実行中だけ保持する。次回・再起動後は永続 cursor から再取得し、同一 revision を再適用しない。
- SSE に加えて、送信 queue が空でなくても5秒間隔の受信確認を行う。同一 DB / Workspace の受信は transfer 用 worker とも重複させない。接続・復旧状態と mutation generation を適用時に再検査する。無関係な ACK では進行中の通常受信を無効化しない。
- Server の差分は現在の正本を返し、削除は null revision を持つ。小さい数値 revision はそのまま上書きせず、削除・再作成が集約された可能性を snapshot 復旧で確認する。復旧・reset は未送信操作や録音を保護する一貫した適用単位を維持し、部分適用しない。参照が残る file の削除も保留して後続の参照削除を待つ。
- 受信と送信待ちの競合判定は、関連する親 Project・Meeting・File の ID だけをローカル操作から読む。保存済み operation payload と公開 API の canonical response は別契約であり、画像 metadata の `ocr_text` などを response 用モデルで復号しない。送信待ちの本文や metadata の差異で独立した受信を止めず、関連する操作の保護は維持する。
- 会議単位の要約準備では、通常差分を対象会議の依存・lifecycle 世代で検査し、無関係な ACK や保留 entity によって待機を延ばさない。要約待機は対象会議の入力と依存へ限定し、Notes 同期失敗を省略で回避しない。
- 移管確認 GET を接続・Workspace・origin・lifecycle 世代ごとに共有する。変更なしの push 事前確認だけ5秒再利用する。pull の適用前確認は再利用しない。復帰・stop・移管で破棄し、commit の403/404/409では再確認する。結果適用時も接続と lifecycle 世代を再検証する。Server の commit 時の認可・所属検証は省略しない。

## Server のロック

PostgreSQL のロックは認可、Workspace lifecycle、domain、Document、Workspace publication に分ける。順序と複数 ID の昇順を守り、途中で追加・昇格しない。RLS・暗号化は維持する。SQLite は transaction の直列化で扱う。

- 通常の更新は認可・Workspace lifecycle を共有取得する。旧 Server の domain 排他との互換用に domain キーも共有取得する。会議の本文・metadata、file、recording session、Project の親子関係を対象 ID ごとに保護し、必要な旧・新の関係を一度に昇順取得する。取得後に所属が変わっていた場合は `503 sync_target_changed` で immutable request を再試行する。
- 会議の作成・削除・復元は親 lifecycle を排他、通常更新と Documents は共有にする。Documents は会議の本文更新ロックを取得しない。Workspace の削除・reset・移管、認可変更は排他にする。
- canonical 更新の終了後に短い Workspace publication 排他を取得し、Memory キューの無効化、change sequence の採番、delta ledger、latest cursor、receipt を同じ DB transaction で確定する。差分・snapshot は publication 共有で読む。採番後に別の transaction が先に commit して cursor が未公開変更を飛び越す状態を防ぐ。重い本文更新全体を Workspace 単位に直列化しない。
- 認可の全体キーを排他取得するのは Workspace の作成・reset など権限が変わる操作だけとし、Workspace の名前・設定の更新は自 Workspace の lifecycle 排他にとどめる。
- 操作が64件を超える transaction は資源ごとのロックを取らず Workspace lifecycle を排他取得し、PostgreSQL の lock table を使い切らない。
- 同期 transaction のロック待ちは30秒で打ち切り、ロック待ち超過・deadlock・直列化失敗は `503 database_busy` として client に再試行させる。
- 旧 Server が使う全体認可キーと Workspace キーも取得するため、旧インスタンスと混在している間は旧ロックによる待機が残る。
- 録音 staging の期限切れ清掃は delta GET では行わず、storage maintenance sweep で実行する。
- アップロード要求時の期限切れ staging 清掃は、domain gate を排他、Workspace lifecycle を共有で取得する。清掃と domain の予約・確定は競合させるが、Documents は待たせない。清掃対象は file 最大25件・recording 最大100件に制限する。定期 maintenance の Workspace 排他は維持する。
- transcript chunk の要求時は、同じ Workspace で期限切れ staging がある最大100会議とアップロード先をまとめてロックして清掃する。別会議で放置された patch も後続アップロードで回収し、fresh な chunk と別 Workspace は残す。Workspace 全体の排他にせず、ロック取得後に対象を追加しない。
- ファイル・文字起こしの staging 受付と期限切れファイル予約の削除は、Workspace ロックを取得してから行う。

## Delta、イベント、削除

Server は Workspace ごとの durable change ledger と opaque cursor を持つ。delta は high-water cursor を固定し、その境界までの各 entity の最終 canonical state をページングする。一時的な delete / recreate を露出しない。pull checkpoint は対応ページの適用時だけ進め、commit receipt の cursor で代用しない。

`GET /api/v1/events` は本文を含めない SSE invalidation。Web は開いている Notes の通知も同じ接続へ集約する（購読・再接続・通知基盤は [Documents](documents.md#web-の変更駆動同期)）。通常の cursor と文書の revision を別イベントとして扱い、送信レーンや ACK は統合しない。起動、foreground 復帰、再接続、イベント欠落は必ず delta API で追いつく。Web も同じ transaction endpoint を使い、同期データの Server MCP は read-only。OAuth と認可は [共通 OAuth](oauth.md) と [Workspace permission](../server/database-and-identity.md#workspace-permission) に従う。

### 90日保持と正本からの復帰

change ledger は同期専用として90日の差分復帰を保証し、それ以前と新規端末は正本 snapshot を取得する。Workspace ごとの最新 sequence と削除済み境界を永続化し、境界更新と履歴削除を同一 transaction にする。delta の全ページが境界を検査し、期限切れと最新 sequence を超える cursor（Server の復元後に残った cursor など）は `410 sync_cursor_expired` とする。

snapshot は entity / ID の keyset pagination と開始 cursor を返す。複数リクエストを跨ぐ DB transaction は持たず、開始 cursor 以降の delta で追加・更新・削除を補正する。開始 cursor が期限切れなら再取得する。Desktop は内容を一時 SQLite に退避し、取得と補正の完了後に remote applier で適用する。未送信 queue がある間は適用せず、編集・接続変更の永続 generation と録音状態を各適用 transaction で検査する。不一致なら削除照合・checkpoint 確定を保留する。内容書き込みはページで区切り、全体の内容をメモリに展開しない。Project と照合用 ID は applier の metadata 集合を再利用する。

receipt 本文は90日後に縮約し、ID・操作者・Workspace・正規化 request hash・結果 ID / revision・commit cursor は保持する（account削除は禁止）。再送前の resolve は staging を実行しない。縮約 receipt は該当 queue を ACK して正本取得を要求し、pull checkpoint を進めず後続編集を保持する。未処理 operation の ID・本文・base revision は変えず通常の409で競合を検出する。一律 rebase は行わず、明示的な Server version 採用だけを例外とする。Web も縮約結果から最新の正本を再取得する。

削除は初期無効の明示管理コマンドで日次実行し、通常リクエストには入れない。Server 時刻による90日超の履歴・本文だけを小分けに処理し、commit と同じ Workspace ロックを使う。migration、全 Server、対応クライアント、復帰検証、削除有効化の順とし、本番適用と scheduler 設定は別の運用操作にする。旧クライアントへ縮約結果を通常成功として返さず更新を要求する。会議データの保存期間は変えず、軽量 receipt が増え続けることは許容する。D1 はサポート対象外。過去の未リリース baseline 整理は、released migration の変更を許可する前例ではない。認証方式・proxy の user ID 変更は既存 permission を自動移行しない。

会議の削除は、親だけでなく summary / transcript / screenshot の canonical key も同じ transaction で無効化する。同じ会議 ID の削除・再作成が delta で集約されても、snapshot に退避された旧子データを再適用しない。期限切れ後に書込可能な Workspace が存在しない場合は、残っている reset event と同じくローカル内容・録音を保持して confirmed sync state だけを解除する。Viewer のローカルコピー削除は role を確認し、実際の行削除が成立した場合だけ退避音声の削除を確定する。

### 会議イベントと録音セッションの表示

Server の調査用履歴は `meeting_events` に保持する。会議の作成・メタデータ変更・削除は Server の確定 transaction 内で記録し、変更した項目名だけを残す。Server Account の Desktop はタグ付与・解除、成功した録音開始、終了、音源ごとの物理セグメント切り替えを永続 queue から送る。Local Account、タグ名、変更前後の本文、音声、ファイルパスは対象外。切り替えはファイル確定成功とは区別し、初回ファイル作成では発生させない。

`capabilities` の `meetingEvents: { version: 1 }` を確認した接続だけで送信を有効にする。イベントは ID で冪等化し、履歴は Server だけに残す。開始・終了イベントから `recording_sessions` SQL view を構成し、未終了セッションがある会議を Web の一覧・詳細・サイドバーで録音中と表示する。生存通知や有効期限、状態カラムは持たない。終了情報が同期されるまで表示が残る。会議を削除すると、それ以前の開始イベントによる録音中表示は終了し、復旧しても再点灯しない。録音・保存はネットワークを待たず、他端末のセッションをローカルの録音テーブルへ適用しない。

イベント履歴は同期差分の90日保持とは独立し、期間削除や過去操作の補完は行わない。会議の論理削除時は復旧用に保持し、物理削除時に追加情報を除去して ID・種別・時刻だけを残す。Workspace 削除時は履歴も消す。調査は DB から行い、閲覧 API や専用 UI は持たない。

削除済み・無効・削除処理中の会議に届いた遅延イベントは `410 meeting_event_parent_unavailable` とし、Desktop はイベントだけの送信 transaction を破棄する。本文同期をブロックしたり、履歴送信のために会議を復元したりしない。会議読取の録音判定は対象会議の開始・終了イベントを索引で検索し、他 Workspace の全履歴集計を避ける。

### 会議の遅延削除と復旧

Server の `meeting:delete` は `deleted_at` を記録する論理削除とする。Workspace の `meetingDeletionGraceDays` は整数1〜90日、初期値7日で admin だけが変更できる。期限カラムは持たず、削除済み会議にも現在の設定を適用する。設定・ごみ箱 UI は Web だけに設け、Local Account の削除は変えない。

通常の読取・検索・MCP・子データ取得は削除済み会議を除外する。本文・要約履歴・イベント・録音・画像関連付けは保持し、古い更新・アップロード・同一 ID の create では復活させない。処理中の要約ジョブはキャンセルする。削除は親と子の delete 通知を発行し、`meeting:restore` は現在の削除済み revision を検査して親の revision を増やし、保持した子の upsert を親から順に再通知する。子の revision は巻き戻さない。物理削除前なら期限後も復旧でき、再削除はその時点から数える。画像単独削除は即時で、消した関連付けを復旧時に再作成しない。

ごみ箱 API は現在の Workspace 閲覧権限を要求し、復旧は admin/editor に許可する。Node/Workers のメンテナンスは通常 commit と同じ Workspace ロック下で現在設定を再読し、対象を小分けに物理削除する。関連 files は他の会議に参照がなければ削除し、録音と共に永続 storage 削除キューへ入れる。DB 削除は storage 未設定でも実施する。ごみ箱が残る Workspace は空とみなさない。

## ファイル

原本は Workspace 所有の `files`、会議との関係は独立 ID の `meeting_attachments` に保存する。`files` の基本項目は `uri`、`offset`（現在は0）、`size`、`content_type`、`checksum`（`SHA-256:` 接頭辞）とし、source / OCR / caption / 寸法は metadata に置く。source は作成時に固定し、metadata の部分更新は未指定キーを保持する。同じ Workspace の複数会議で同じ file を共有でき、紐付けを解除しても原本を削除しない。参照が残る明示 file 削除は拒否する。

- アップロードは JSON の `POST /api/v1/file-uploads` で ID・Workspace・属性・MIME を予約し、`PUT /api/v1/file-uploads/{id}/content` へ octet-stream を送る（[OpenAPI](../server/openapi.md)）。最大64 MiB、Content-Length 検証、Server 側の streaming SHA-256、同一再送の成功・異内容409、Transaction 確定まで private staging とする。その後に `file` / `meeting_attachment` transaction で確定する。pending は通常の一覧から除外し、24時間後は再 upload を要求する。
- 確定済み file の OCR / caption / 寸法は `PATCH /api/v1/files/{id}` でも更新できる。baseRevision と metadata の JSON 部分更新を受け付け、未指定キーを保持し、OCR / caption の null はクリアを表す。source と bytes は不変。metadata 更新は認可後に Server 内部で単一の `file:upsert` transaction を生成し、既存の競合検出・検索更新・durable delta を通す。
- 原本 key は `files/{fileId}/original`、派生画像は `files/{fileId}/variants/v1/{variant}.webp`（`thumb_480` / `thumb_1280` / `thumb_1568` / `thumb_1920`）。File API は Databricks Volume に保存し、canonical URI は `/Volumes/.../files/{fileId}/original` とする。旧 key の migration は行わない。
- 原本とその HEAD は `/api/v1/files/{id}/content`、JSON metadata と metadata PATCH は `/api/v1/files/{id}` に分ける。HEAD は本文を送らず、各 storage の HEAD / stat を再利用する。アプリの metadata を独自 HTTP header に移さない。公開 DTO は `contentType`、`contentUrl`、`ocrText` を使い、内部 URI / offset を返さない。DB の `uri` / `offset` / `content_type` / `ocr_text` は保存形式として維持し、境界で変換する。
- GET / HEAD の原本と variant は Workspace 認可、CSP sandbox、nosniff、Range を適用する。source は認可条件にしない。原本・variant は `private, no-cache` とし、クライアントは保存した画像の再利用前に現在の認可を再確認する。ETag が一致すれば304を返し、画像生成・ストレージ読込・画像転送を省略する。ただし `If-Unmodified-Since` も指定された場合は Range を除いた HEAD で日時条件を先に検証する。削除・権限失効後の要求は404を返すが、すでに画面に表示中の画像を消す通知は行わない。`Vary: Authorization, Cookie` で認証状態ごとのキャッシュを分ける。

### 画像の variant と保存形式

Server は一覧用の長辺最大480px（`thumb_480`）、1280px（`thumb_1280`）、プレビュー用1568px（`thumb_1568`）、1920px（`thumb_1920`）を長辺上限として、縦横比維持・拡大なし・WebP quality 80 で作る。Node は `sharp` を使用し、最初の参照時だけ生成して Volume に保存する。upload / commit では生成しない。変換は最大2並行で同じ画像・variant の処理を共有する。生成や保存の失敗はエラーとし再試行できる。変換器を持たない環境は variant を広告しない。variant endpoint が原本を返すことはない。Web は1568px版を開き、原寸へのリンクも残す。コピー・書き出し・明示的な原寸取得は原本を使う。Server 内の AI 処理は HTTP 応答生成から分離した認可付き画像取得を再利用する。

Desktop はスクリーンショットを撮影時に長辺1568px以下の WebP で保存し、それより前のローカル Workspace の画像も起動後に一度だけ同じ形式へ変換する。要約・OCR・キャプション・MCP には保存済み画像をそのまま渡す。1568px は Claude の標準解像度の上限で、Retina の画素を保存しても可読性は上がらず、エンコード時間と容量だけが増えるため。MCP に `image_size` 指定はない。チャットの添付画像は1280px上限とする。旧 `thumbnail` / 384px 経路は持たず、派生キャッシュの一括移行は行わない。撮影原本、サムネイル、リサイズ・書き出し時の再エンコードは品質80に統一する。Local Account は原本だけを永続保存し、表示時の縮小デコードはメモリ cache / decode worker に任せる。

### 画像解析の実行場所

画像解析の実行場所・アカウントごとの設定・同期での新規処理受付は [アカウント別 Desktop 推論](account-scoped-desktop-inference.md) に従う。Desktop の解析 job は待機・処理・失敗を表示し、同期済み画像の OCR / caption は端末 job の有無によらず共通 provider で取得する。Server の受理済み job の復旧・結果確定は [画像解析と受理済みジョブ](../server/search.md#画像解析と受理済みジョブ) に従う。

## 端末での部分保持

### ローカル参照と表示

Local / Server の両アカウントで UI の読み書きは `MeetingRepository` を通す。保持済み本文・要約・文字起こし・OCR は SQLite から読み、同期済み revision の観測で開いている会議の projection を更新する。文字起こしは閲覧中の bounded window を再読込し、過去を読んでいる位置を末尾へ飛ばさない。ウィンドウヘッダーのアイコンとホバーヘルプで、表示中の会議の端末への保存と Server 同期完了、保留・復旧・競合を区別する。本文の未取得・取得中・失敗と再試行ボタンもヘッダーに表示し、同期状態の変化やタイトル編集中も本文のレイアウトを変えない。

アカウントメニューとフッターのアイコンは接続先に属するワークスペースの同期状態を集約し、未完了・復旧・エラーがあれば同期済みより優先して表示する。サイドバー右のメイン領域のヘッダーに Workspace / Project の親階層 / 会議名を同じ文字サイズで表示する。各パンくずのプルダウンはホバーから0.3秒後に下向きに開く。Workspace のプルダウンには同じ接続先の Workspace だけを表示し、配下の Project は混在させない。Project は同じ親を持つ Project、会議は同じ Project の会議へ移動できる。プルダウンの先頭にはリソース種別のラベルを表示する。パンくずの要素名を繰り返すツールチップは表示しない。プルダウン内のプロジェクト行は通常の文字色で表示し、クリックでプロジェクト詳細へ移動する。ホバーで右側へ配下のプロジェクトと会議を展開し、サブメニューが親の行のクリックを遮らないようにする。会議一覧は開いたときに20件ずつページング取得する。

Desktop のミーティング詳細は、固定ヘッダーと本文の間に 32pt の余白を設け、タイトル・メタデータ・タブ・本文を同じスクロール領域に置く。スクロール時はメイン領域と同じ背景色の固定ヘッダーの背後に内容が流れる。本文を中央寄せする幅制限はスクロール領域の内側へ適用し、縦スクロールバーはメイン領域の右端に表示する。文字起こしのページ読み込みと最新行への追従、スクリーンショット一覧の仮想化はスクロール所有者で維持する。ノートのエディターは本文に応じて高さを調整し、4096pt を超える長い文書だけ内部スクロールに切り替えて native viewport の高さを制限する。本文の保存・編集範囲は制限しない。

アカウントメニューとフッターは同期中の残件数を併記し、「同期の進捗」から Workspace 別の準備中・本文同期中・添付転送中・変更取得中・再試行待ち・要対応・同期済みを確認できる。残件は未確定の operation ID ではなく対象 entity ID を重複排除し、meeting / summary / transcript は一つの会議本文として数える。file と添付関連付け、その他の変更は別に集計する。アップロードだけでは減らず、receipt 適用後のキューから再計算するため、再起動後も復元できる。準備中は不定進捗とし、百分率・完了予測時刻は表示しない。DB の変更通知を集約し、本文・画像を読み込まず MainActor 外で最大毎秒1回集計する。

### テキスト本文

metadata の全保持と本文の部分保持を分ける。原文を `transcript_segment_bodies`、要約を `summary_bodies`、OCR / caption を `file_text_bodies` に分離し（`v42_localFirstSchema`）、`sync_content_state` に保持 revision、完全性、本文の存在・件数、検証 hash、UTF-8 byte 数、最終利用日時を記録する。本文テーブルは親 ID を主キー兼外部キーとし、原文と document は NOT NULL にする。未保持は本文行の不在で表し、空文字に変換しない。OCR / caption がともに NULL の本文行は取得済みの値として扱う。移行時の本文はすべて専用テーブルへ移し、Server の本文は未検証として残す。Server 観測 revision は `sync_entity_state` が所有する。

metadata の Record は本文を持たず、本文を含む読取結果とは型を分ける。アプリの Repository と MCP は共通 `TextContentAccess` で完全性検査と本文取得を同じ SQLite 読取内で行い、呼び出し元の事前検査に依存しない。ページ取得でも会議全体の欠損を検出し、JOIN が欠損行を黙って除外しない。一覧・検索用の cached projection は明示した別の読取口を使う。録音・バッチ結果・本文編集は metadata、本文、同期 operation を同じ transaction で確定する。

snapshot / changes は常に meeting の重複 summary と検索用本文、summary document、file の OCR / caption、transcript 本文を省く。要約本文は meeting 配下の summary/latest、文字起こしは meeting 配下の transcript/latest または transcript/{version} を使う。履歴番号 version と同期用 syncRevision は分ける。file は個別 metadata JSON から OCR / caption（nullable）と revision を1回で取得し、ID・Workspace・checksum・同期済み revision と保存直前の編集保護を照合する。版が違えば通常同期後に1回再取得し、不一致や失敗では旧本文と未取得状態を保持する。依存取得は metadata のみ反映し、本文補完から confirmed revision を更新しない。不要となった text/file は削除する。

`MeetingContentProvider` は SQLite を先に読み、古い完全な内容も stale として利用できる。明示操作・UI・AI・MCP は共通の保持 lease を使う。文字起こしは一時 table に500件以下のページで取り込み、指定 revision、全体の件数・byte 数・hash を照合してから remote applier の transaction で反映する。中断した一時行は掃除する。summary は会議単位、OCR / caption は共有 file 単位で取得する。本文 I/O は pull checkpoint と録音の永続保存を進めない・待たせない。要約・文字起こしの同期済み revision と manifest・件数・hash、file は個別 metadata の同期済み revision を検証して本文を反映し、metadata や confirmed revision は更新しない。

表示中の OCR / caption は未完了または stale なら2秒間隔で確認する。完了条件は Server の解析判定と揃え、空の OCR は有効、caption は空白除去後に非空であることを要求する。Server の解析 job 状態は本文 API に含まれないため、5分で自動取得を停止し、取得済み本文を残して再取得操作を表示する。画像を開き直すか再取得すると待機を再開する。ネットワーク待機を録音・確定文字起こしの保存経路へ持ち込まず、本文の破棄・eviction は Workspace 全体の未送信・復旧状態と録音状態で保護する。

manifest hash は各 nullable UTF-8 field の `byteLength:bytes`、NULL は `-:` を SHA-256 に入力する。文字起こしは startTime / UUID 順の lowercase segment UUID と原文、summary は document、file は OCR の後に caption。UUID は本文 byte 数へ含めない。Swift / Server は共通 fixture で一致を検証する。既存本文の hash が同じなら本文 download を省くが、文字起こしの保持 revision が変わる場合は時刻・話者・音声ソースも取得してから revision を進める。同じ revision で内容が違えば元データを残して自動解放しない。

反映・解放 transaction は接続 ID / origin、Workspace、mutation generation、対象の存在、revision、queue、復旧・録音状態を再検査する。権限・所属の変更は generation で進行中取得を失効させる。状態は missing / loading / failed / ready / stale / empty / deleted を区別し、失敗で完全な旧本文を消さない。

本文編集は完全性を検査し、操作の base revision は編集した保持 revision を使う。明示的なローカル版再適用だけが最新 revision を使える。未保持会議への録音追加は durable write を使い、不足する過去本文を完全にしたと判定しない。Local Account への移動は metadata 同期、全本文・画像原本取得後に、各 Workspace の Server high-water cursor が取得開始時の同期済み cursor と一致することを再確認する。不一致や通信失敗では移動を中止し、再試行時に同期と取得をやり直す。確定 transaction 内でも接続 generation・同期済み cursor・完全性を再検査する。失敗時は接続・queue・ローカル変更を保持する。

Server 版の採用や確定済み Workspace の無効操作破棄では、破棄対象の本文だけを同じ transaction で未保持表現へ解放し、Server revision が変わらなくても正本を再取得する。本文行を削除し、対応する FTS と開いている表示 projection も更新する。行・metadata・翻訳・音声特徴量は保持する。未確定 Workspace の初期アップロード再構築と、明示的なローカル版再適用ではローカル本文を保持する。

会話分析は Desktop の本文保持・Repository・バックグラウンド処理から分離し、Server が指定された文字起こし版と確定録音から同期計算する。Desktop は版付き結果を表示するだけとする。詳細は [会話分析の Server ownership](conversation-analytics.md)。

### 画像

画像一覧は metadata だけを保持する。`ScreenshotContentProvider` が移行待ちの旧 BLOB、共通ファイル、認証済み Server read を解決する。delta / snapshot は画像ダウンロードを待たず metadata を適用する。Server Account の画像は未送信分と取得済み分を Application Support/Dahlia/FileStore/server/{accountConnectionId}/files/{fileId}/original の同じ immutable file として管理する。画像行の `localReference` と送信 operation の `attachmentReference` は独立して同じファイルを指すため、画像行を削除しても確定前の送信に必要な原本を保持できる。

- 撮影した原本を検証・確定した後、metadata と送信 operation を同じ SQLite transaction へ保存して完了を通知する。
- Server は原本の削除待ちがある間、upload 完了の反映と file の確定を DB transaction 内で拒否する。同じ ID の再予約も削除完了後に原本を再送する。現在の予約が有効で削除待ちだけが原因なら503で自動再試行し、予約自体が消えた場合の404とは区別する。
- Server の staging upload 成功では保持を解除せず、同じ接続・Workspace・hash の canonical revision と未処理 operation の参照を検査する。未送信、再試行、競合、確定状態が不明な原本はキャッシュ容量の対象外とし、確定後はコピー・移動なしで削除可能となる。添付のないメタデータ編集も含め、保留中の transaction がある Workspace では取得済み原本を保持する。
- receipt は後続の会議削除で消えた子を復元せず ACK し、Server の添付競合は欠損した親会議を返して明示的なローカル版の再適用で復旧できるようにする。
- ファイル確定中とアカウント移動中は削除を止め、アプリの所有者だけが DB writer 内で参照を再検査して有界な件数を削除する。取得済み画像の破損は再取得できるが、未送信画像の欠損・破損はエラーとして保持する。ファイルストアを開く処理や読み取りだけで画像を削除しない。cache の追加・削除・破損回復は domain transaction と pull cursor を変更しない。

クラウド画像のファイル cache は全 Workspace 合計で既定2 GiB、設定は1 / 2 / 5 / 10 GiB。LRU で上限超過時に80%まで戻し、サムネイル用に20%を残す。未使用枠は原本も利用できる。ローカル原本、未送信原本、backup 世代はこの上限の対象外。ファイルパスはアカウント接続 ID・file ID・生成 recipe で決め、索引に原本 hash と保持状態を記録する。サムネイルは索引の原本 hash が現在の file と一致する場合だけ再利用し、索引に未記録の項目や ID 再利用時は再取得する。会議や Workspace の ID はパスに含めない。取得は最大4並行、不要な表示要求はキャンセルする。書き込みは atomic とし、読込時に長さと hash を検証する。キャッシュが書けなくても取得した画像を表示できる。

MCP の画像参照は同じファイルストアを read-only で利用し、作成・削除は行わない。未取得の場合は起動中のアプリへ画像や不足本文を要求する同梱 helper 用 IPC を使い、同じ OS ユーザーと同梱 helper executable を確認し、アプリ側でも Workspace / 会議 / 画像の所属を検証する。token broker の権限は広げない。未取得・破損画像をリストから黙って省かず、取得不能として返す。

未リリースの v42 は screenshots table を files と meeting_attachments に移し、既存画像 ID を両方の ID に引き継ぐ。旧 BLOB は file_migration_content へ退避し、ファイル検証後に解放する。operation は独立した attachment reference を持つ。v41 以前の BLOB はファイルの検証と参照切り替えが成功した分だけ解放し、移行前の retry 用 BLOB 保護は維持する。移行は起動時と同期前に再開でき、失敗時は元データを保持する。Local Account から Server への移動もファイルを準備し、所属変更と参照の切り替えを同じ transaction で確定する。未リリースだった旧 v42 と旧 cache 形式の互換処理は持たない。次の canonical metadata 取得で既存画像の Server 参照を確定する。解放した SQLite ページは次回起動時、録音開始前に空き容量を確認して標準 `VACUUM` で回収し、以後は録音外で incremental vacuum を行う。失敗時は元の DB を維持して後の起動で再試行する。

### 容量と最低保持期間

全 Server Account 合計128 MiB を超えると、再取得可能な検証済み本文を LRU で80%まで解放する。直近20会議は空き枠内だけ先読みする。閲覧済み本文を先読みのために追い出さず、解放した項目を次の先読みで取り直さない。Local Account、使用中、未送信・競合・復旧中の Workspace、録音中は対象外。容量は本文と Documents を数え、metadata・翻訳・session・音声特徴量・ユーザーの Markdown・backup を含めない。解放は本文行だけを削除し、transcript metadata・summary header・file metadata と export 参照、端末固有属性を保持する。対応する FTS・旧 vector を除去し metadata 索引を再構築する。起動時 VACUUM と録音外 incremental vacuum で空きページを回収する。

Server Account の端末内本文・Documents・取得済み画像には、この Mac 全体で適用する最低保持期間を設ける。設定の「データ保護」>「データ保護」で1日以上の日数または無期限を選択し、既定は無期限とする。Server 連携直後に過去分が意図せず解放されることを防ぐ安全装置として、利用者が日数を選ぶまで容量整理による削除を行わない。無期限を解除したときは30日から設定できる。端末の UserDefaults に保存し同期しない。

- 作成・ローカル編集・明示的な閲覧・初回取得で保持期間を開始または更新する。MCP の画像キャッシュ参照も IPC でアプリへ利用を通知する。helper は read-only のまま、利用日時の更新はアプリが行う。アプリ不在・通知失敗時も取得済み画像を返す。同期、アップロード、整合性確認だけでは延長しない。利用日時が不明な保持済み本文・文書は、それを導入した migration の時刻から保護する。
- 本文と Documents の128 MiB、画像の設定容量を超えても、最低保持期間内の内容は解放しない。期間経過は削除の必要条件とし、容量超過時だけ背景整理で古い内容を解放する。無期限では容量整理による解放を停止する。
- 未送信・競合・復旧用・Local Account の内容と録音中・利用中の保護は期間と独立して維持する。設定変更は次の整理時に反映し、延長や無期限への変更で全件取得は開始しない。
- 保持済みの内容は SQLite／FileStore から読む。未取得・解放済みの内容は必要時に取得し、取得不能を空本文や削除として扱わない。Server 停止中の保証は端末に残る内容の閲覧・ローカル保存・送信待ちの保全に限る。明示削除・同期された削除・権限失効には通常の契約を適用する。録音音声の保持・Server 処理への依存と、Server Account のバックアップ対象外という境界は変えない。

## Documents 専用同期

明示公開した会議 Notes の同期・復元・presence は [Documents](documents.md) が定める。端末内 note は同期せず、MCP は read-only。本文更新は transaction キュー・receipt・pending による受信 defer の対象にせず、文書ごとの CRDT 差分 API と送信待ちで処理する。送信待ちでも受信をマージする。[独立した Document](document-identity.md) により文書は Workspace に属し、会議との関連は任意となる。会議の物理削除・reset は関連する文書を除去し、soft delete は関連する全用途の generation を更新して古い編集を拒否する。会議のない文書は Workspace のライフサイクルに従う。復元は新しいブロックの挿入とする。

- DB ごとの DocumentSyncService を共有する。Desktop はローカル commit 後200ms 固定窓で送信し、表示文書は専用 SSE を共有する。Web は100ms 固定窓。切断補完は2秒、flush は即時、親会議 ACK を先に待つ。

## Workspace の全内容移管

両 Workspace の Admin が Server に保存済みの全内容を移管する。Editor はこの操作を行えない。元の Workspace は空で残し、削除は別操作とする。

未同期データ自体は移管対象に含めない。ただし、実行時に未同期データを検知できる場合は移管を拒否する。Server が確認できる upload staging や未確定の処理と、Desktop が確認できるローカル送信待ちは区別する。Web からオフライン端末の送信待ちがないことは保証できず、検知できない状態を「同期済み」と表示しない。

移管は `POST /api/v1/workspaces/{workspace_id}/transfer` で両 Workspace を ID 順にロックし、一つの DB transaction で所属を更新する。ID・実体ファイルは維持する。元と先の revision を検証し、UUIDv7 の `Idempotency-Key` は所有者単位で保存する。同じ要求の再送は同じ Server 生成 ID を返し、異なる要求での再利用は409とする。

Desktop が reset の差分を複数ページ取得する場合は、全ページ取得後・適用直前にも移管を再確認し、途中で移管された会議やローカル録音を削除しない。

共有設定は移管先の設定を継承する。確認時には実際の閲覧者を組織・チーム所属から求め、閲覧できなくなる人と新しく閲覧できる人を表示する。確認時の閲覧者ハッシュを移管要求に含め、実行時に一致しなければ409で再確認を求める。PostgreSQL では確認から commit まで権限・組織所属・チーム所属の変更をテーブルロックで止める。

Desktop は移管を削除として適用しない。差分・snapshot の適用前に `GET /api/v1/workspaces/{workspace_id}/relocations` で既存 ID の現在の所属と権限を確認し、必要な所属変更・参照・同期状態をローカルの一つの transaction で更新する。録音の実体は変更しない。権限がない間、またはローカル送信待ちの transaction・録音アーカイブがある間は、データと所属を保持して同期を停止する。権限復旧後は次の同期で再確認する。専用のバックアップ・破棄画面や、クライアントごとの移管履歴の適用位置・ACK は設けない。送信の再試行では移管の送信待ち検査より先に transaction レシートを解決し、確定済みの処理を受領する。移管の確認・復旧に失敗しても、他の Workspace の受信と送信は継続する。

移管レシートに対象 ID を保持し、通常差分の期限切れ・元 Workspace の削除後も現在の所属を解決する。移管に関係した Workspace では、`X-Dahlia-Workspace-Transfers: 1` を送らない旧クライアントの差分・snapshot と書き込みを426で停止する。このヘッダーは対応能力の宣言であり、適用済み位置を表さない。

Local から既存 Workspace への取り込みは、WorkspaceRelocation の所属変更 primitive を使い、Project／Meeting／file と従属データの ID・本文・翻訳・録音 path を保持する。元 Workspace の設定・instructions は残す。所属変更、移行記録、通常 create/upsert キューを単一 SQLite transaction で保存し、移行時の operation ID（画像・録音 upload を含む）の ACK を永続追跡する。後続編集・録音を継続でき、キュー全体が空になるのを待たない。409／権限失効時は未送信変更・バックアップ・元 Local Workspace を保持し、Server への部分確定を自動 rollback しない。Server に存在しない再接続データは [再接続](../desktop/workspace-reconnection.md) に従い保全し、自動送信しない。

## 利用者による受信エラーの復旧

`invalid_sync_payload` は、同期処理で形式・公開 ID の読み取りに失敗した状態として表示する。受信以外のローカル処理でも発生し得るため、Server のデータ不正と断定しない。API 名、エラー種別、許可したスキーマ項目名だけを端末内の incident に保持する。レスポンス本文・値・認証情報・decoder の自由文は診断へ含めない。同期画面から利用者が診断をコピーできる。

「Server から再取得」は Server の reset や送信待ちの破棄ではなく、snapshot 復旧を明示的に開始する。開始時に通常の送信待ち、Documents の未送信差分・復元記録、録音、Workspace 移管を検査し、保護対象があればカーソルを変更せず案内する。開始後も接続・変更世代・未送信操作による snapshot 適用制御を維持する。壊れたレスポンスを読み飛ばしたり、失敗した差分の先へカーソルを進めたりしない。Server の最新状態にも形式不整合がある場合、再取得だけで直るとは扱わず、診断を共有して Desktop / Server 側の修正を行う。

## 計測

外部 telemetry や内容・識別子の診断出力は加えない。

- Desktop は Instruments の Points of Interest に、`com.dahlia` / `SyncPriority` の固定名 interval を出す。`DocumentLocalCommit` とその中の `DocumentDatabaseWrite` で保存全体と DB 占有を分け、差分を DB 待ちの目安とする。`DocumentSendWindow` は200ms 集約待ち、`DocumentExchange` は文書同期の呼び出し全体、`DocumentApplyToWebView` は受信状態の JavaScript 適用までを測る。最後の interval は画面の pixel 表示完了を意味しない。内容・ドメイン ID・パス・認証情報を signpost へ渡さない。
- Server 内部の `captureSyncTimings()` は明示的なローカル計測だけに使う。固定名フェーズと最大128件の時間だけをメモリに保持し、`stop()` で解除する。公開 HTTP API や環境変数、外部送信は持たない。`connectionAndBegin` にはプール取得と BEGIN の両方が含まれ、純粋なプール待ちではない。`transaction` は DB callback 内の処理全体で、個別の認可・lifecycle・domain・document・notes のロック待ちは別 interval とする。ロック待ちを処理時間へ二重加算しない。
- 再現用の使い捨て DB テスト: `SyncPriorityTests`、`SyncTransferTests` / `SyncTransferSlotsTests`、`DocumentPersistenceTests`、`sync-locks-postgres.test.ts`。`TEST_SYNC_LOCKS_DATABASE_URL` は別会議の並行更新・同一会議の競合・親削除・権限変更・公開順を、`TEST_SYNC_LOAD_DATABASE_URL` は10,000操作の単件／8件送信と通常編集の p95 を計測する。後者は wall clock の揺れを assertion にせず結果を記録する。
- queue/store テストの計測値を、Desktop↔Web や Desktop↔Desktop の通信・描画込みの反映時間として扱わない。ユーザーの QA DB を測定のために初期化しない。

計測値（使い捨て DB でのローカル計測。ネットワーク・画像・transcript・実画面を含まず、新規編集の書き込み性能・QA のネットワーク・実画面の遅延の保証値ではない）:

| 日付 | 計測 | 結果 |
| --- | --- | --- |
| 2026-09-30 | 8,000背景要求に対する通常要求の選択位置 | 旧 FIFO の8,001番目から1番目。claim 6回は9.70〜10.46msで、4通常要求の後に背景要求を選択。送信完了までの時間ではない |
| 2026-09-30 | 短い文書の同一差分30回再送の transaction 内処理 p50/p95 | 通常4.42/4.71ms、同 Workspace の domain ロック保持中4.65/5.00ms |
| 2026-10-02 | 10,000 Project 作成 | 単件送信147.82秒、8件送信32.81秒。同一ホストで他の検証も実行中 |
| 2026-10-02 | 同じ Workspace の会議編集30件の p95 | 通常24.04ms、取込中31.00ms |

## 未適合・未検証

- 実画面の Desktop↔Web／Desktop↔Desktop の反映時間、実際の大量取り込み中の録音・描画は未測定。専用アカウントとデータを用い、通常時と8,000件取り込み中に同じ編集・要約開始を行い、signpost と相手側の描画時刻から p50/p95 を比較する。自動テストの成功をこの比較の完了とは扱わない。
- 初期構築と通常編集を合わせた QA 実機での目標達成は未確認。
- 初期 snapshot の構築中に録音や別 mutation が始まったときに部分 snapshot を捨てる規則と、初期構築を entity ごとに再開する規則の関係は確定していない。
- Databricks Apps + Lakebase では 2026-09-02 に owner read/write、upload、Range、delete と RLS identity の非漏洩を確認した。全 deployment の検証済み宣言ではない。配置時には non-superuser / NOBYPASSRLS、FORCE RLS、同一 pinned connection での COMMIT / ROLLBACK 後の identity 非漏洩を fail-closed probe で確認し、失敗時は application-only 認可へ縮退しない。

## 却下した案

- PowerSync / Electric: 片方向 upload の段階では不要だったため採用していない。将来の全同期方式としての禁止ではない。
- 画像・transcript chunk・manifest を順に送り、backup restore 時に Server Workspace を削除して再送する owner-only upload: 双方向編集で履歴の欠落、競合、二重実行を防げないため、domain transaction と canonical delta にした。
- Workspace 単位の FIFO 送信と、blocked 以降の一括停止: 2026-09-30 の計測で、8,000件の背景要求があると通常要求は8,001番目に選ばれた。優先度と依存による送信にした。
- Workspace 内の全 domain 更新の排他: 重い本文更新が同じ Workspace の他の更新を待たせるため、対象 ID ごとのロックと短い publication 排他にした。

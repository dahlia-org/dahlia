# Server の canonical sync

対象: Server・Private Web。Desktop（macOS アプリ）は同期しない（2026-11-23 にユーザーが承認して削除した。Desktop の同期は未リリースだった）。採択: 2026-09-02〜09-03。送信の優先度と Server のロック分割は 2026-09-30、更新単位のロックは 2026-10-02 にユーザーが承認した。API の詳細は [Server README](../../../apps/server/README.md)、ローカルの保存保証は [Architecture](../../../ARCHITECTURE.md) を参照する。

## 正本とアカウント境界

Server Workspace / Project / meeting は Server canonical record とし、Web がこれを読み書きする。Web は Organization context を持たず、権限のあるすべての Workspace を既定で表示する。Organization による絞り込みは必要になった時点で Workspace 一覧へ追加する。

Desktop は Server と同期せず、Server Workspace を発見・取り込み・再接続しない。Desktop の Workspace はすべてアプリのアカウントのローカルデータである。同期の列（`workspaces.accountConnectionId`・`organizationId`・`personalUserId`・`sync*`）とテーブルはリリース済みの schema に残し、起動時にすべての Workspace で列を空にする（[Desktop の認証](../desktop/accounts.md#実行アカウントの-context)）。サインインした Dahlia account は Server の Gateway をモデルのプロバイダーアカウントとして使うだけで、Workspace の所属は変えない。以下の契約は Server と Web の契約である。

## 同期対象とモデル

同期するもの: Workspace 名・アイコン・色、2段階 Project 階層と名前・説明・アイコン・色、meeting metadata、meeting のカレンダー情報（下記）、summary document、transcript 原文、screenshot bytes / MIME / OCR / AI caption。新規バッチ録音の結合音声は [専用の音声保管契約](recording-audio-archive.md) で扱う。会議 Notes はこの同期契約に含めず、[Documents 専用同期](#documents-専用同期) で扱う。

同期しないもの: 翻訳文、SQLite ファイル、端末の export path、端末内 note、tag、音声特徴量。

### カレンダー情報

meeting の `icalUid` / `recurrenceId` と `calendarEvent`（`start` / `end` / `is_all_day` / `attendees`）を同期する。UID と recurrence ID はペアで扱い、単発予定の recurrence ID は空文字。`attendees` の省略は既存値維持、空配列は参加者の消去、`calendarEvent: null` はスナップショット全体の消去とする。予定名・説明・URL と端末固有のカレンダー参照は同期しない。暗号化 Workspace では `calendarEvent` 全体を暗号化し DB 列をマスクする。Server の開始・終了・終日フラグは要約の XML context と入力変更検知に使用する。

### Project と transcript

Project は `app.projects` に置き Workspace 権限を継承する。空 Workspace と Project 単独変更も扱い、同じ Workspace の meeting だけが参照できる。Project 削除前に依存 meeting を明示的に移動・解除し、依存が残る削除を Server が拒否する。Project は階層閲覧・明示 filter に使い、検索本文や vector へ混ぜない。

transcript の収録経路は `audio_source: mic | system`、人・diarization の話者は nullable `speaker_label` として分離する。Server の旧 field との互換経路は持たない。

Transcript UUID は生成元で確保して再送でも維持する。Server は `meeting_id` で meeting を参照し `(meeting_id, version)` を一意とする。`workspace_id` は重複保持せず、子 segment の権限も meeting 経由で判定する。生成開始・終了確認は親の `started_at` / `ended_at`、初回 Server 保存は親の `created_at` とする。子の `started_at` / `ended_at` は発話の絶対日時、`created_at` は確定テキストを生成した日時とする。子は確定テキストだけを保存する。

`status` は親の終了確認と子の作成日時から読み取り時に導出し、同期状態や録音状態と区別する。時刻だけでも変化するため同期 revision を増やさず、Web の期限タイマーと読み取り側の再計算で更新する。定義・既存 Desktop データの補完方針は [Audio and Transcription Data Flow](../../architecture/audio-transcription-data-flow.md#transcript-versions) に従う。

### Summary 世代と同期番号

Server の要約正本は `summaries` の最大 `version` とし、meeting に本文や最新ポインタを重複保存しない。世代は Workspace lock 下で発番し、同期の `summary_revision` / `baseRevision` とは独立する。latest の通信形式は `formatVersion`、世代は `version`、同期番号は `revision`。同期 entity ID は meeting ID のまま維持する。全履歴削除後は version を1から再開するが、同期 revision は継続する。receipt、競合応答、削除通知と本文 hash 検証は維持する。

### 外観

Project / Workspace の `icon`・`color` は nullable な正準フィールドとし、ProjectIcon / ProjectThemeColor の保存値を使う。transaction で未指定の項目は保持し、null は設定解除。外観変更も通常の revision・競合検出・snapshot / delta の対象にする。Web と Desktop の編集 UI は同じフィールドを使い、子 Project は親の外観を継承する。子の独自外観は送信・保存せず、親から子への変更時には解除する。`appearance` JSON 列は持たない。

Desktop の旧 `projectAppearances` UserDefaults は Workspace を開いたときに DB へ移行し、旧設定はローカル保存まで保持する。Desktop 専用の `legacyAppearanceMigrated` は再移行を防ぐ印である。

### 生成設定と言語設定

文字起こし言語とライブ文字起こしの保存先は [設定の保存先](../server/database-and-identity.md#設定の保存先) に従い、Server との同期対象に含めない。

Desktop のモデル・推論強度・スタイル・録音後の処理・ライブ下書きの保存先は [アカウント別 Desktop 推論](account-scoped-desktop-inference.md) に従う。Web の Server 処理設定は [処理場所と設定](transcription-summary-processing.md) に従い、Workspace の `generationSettings` は既存の管理者による update transaction・baseRevision・receipt / delta / snapshot / SSE を通す。

開始済みの処理は開始時に固定した設定を再試行でも保持する。

## Capabilities と互換性

`GET /api/v1/capabilities` は機能別の対応 version を返す。`sync` の version は7。ほかの機能の version は、その機能を定める節または仕様に書く（会議イベント、画像解析は下記、Documents は [Documents](documents.md)）。entity revision や payload schema の version とは区別する。非対応の機能はフィールドを省略し、atomic sync 非対応の store は全機能を省いた `200 {}` を返す。認証・運用エラーは通常のエラーとして返す。クライアントは未知のフィールドを無視する。

現在の同期契約は `sync.version = 7` で表す。transaction は schemaVersion 3 を使う。

- 契約を変えるときは互換経路・fallback を残さず、Server と Web を同じリリースとして切り替える。旧契約の相手とは同期せず更新要求にする。契約が異なる開発版同士も更新要求になる。
- 旧フィールドと旧ルートは維持しない。

## Transaction と競合

- `POST /api/v1/transactions` は1 Workspace の operation 群を atomic commit する。transaction schemaVersion 3 を要求する。UUIDv7 transaction ID を冪等キーとし、commit response を保存する。同じ ID と異なる内容の再利用は拒否する。
- Workspace、Project、meeting metadata、summary は optimistic revision を使う。古い base revision は対象 entity と canonical record を含む `409` とし、暗黙の last-write-wins をしない。
- transcript patch と画像は bounded staging endpoint へ送り、その後に元の domain transaction を commit する。staging だけでは read surface に公開しない。全段階で現在の Workspace 権限、ID、親子関係、hash、payload limit を検証する。
- validation、revision conflict、authorization、transport failure は別状態で永続化する。自動 retry は transport error、408、425、429、5xx のみ。
- blocked transaction は、それに依存する後続だけを止める。競合解決の対象は blocked transaction とそれに依存する後続に限る。lease 中・応答不明の transaction は、元 ID の結果を確定するまで破棄・再登録しない。

## Desktop の送信と受信

Desktop の送信キュー・受信・初期 snapshot・競合の解決は削除した。Desktop の SQLite に残る同期のテーブル（`sync_transactions`、`sync_operations`、`sync_entity_state`、`sync_content_state` など）は schema に残し、新しい行を書かない。`sync_content_state` は、取得前の本文を見分けるためにだけ読む（[テキスト本文](#テキスト本文)）。

### 受信

Desktop は受信しない。Web は SSE と delta で追いつく（[Delta、イベント、削除](#deltaイベント削除)）。

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

`GET /api/v1/events` は本文を含めない SSE invalidation。Web は開いている Notes の通知も同じ接続へ集約する（購読・再接続・通知基盤は [Documents](documents.md#web-の変更駆動同期)）。通常の cursor と文書の revision を別イベントとして扱い、送信レーンや ACK は統合しない。起動、foreground 復帰、再接続、イベント欠落は必ず delta API で追いつく。Web は transaction endpoint を使い、同期データの Server MCP は read-only。OAuth と認可は [共通 OAuth](oauth.md) と [Workspace permission](../server/database-and-identity.md#workspace-permission) に従う。

### 90日保持と正本からの復帰

change ledger は同期専用として90日の差分復帰を保証し、それ以前と新規端末は正本 snapshot を取得する。Workspace ごとの最新 sequence と削除済み境界を永続化し、境界更新と履歴削除を同一 transaction にする。delta の全ページが境界を検査し、期限切れと最新 sequence を超える cursor（Server の復元後に残った cursor など）は `410 sync_cursor_expired` とする。

snapshot は entity / ID の keyset pagination と開始 cursor を返す。複数リクエストを跨ぐ DB transaction は持たず、開始 cursor 以降の delta で追加・更新・削除を補正する。開始 cursor が期限切れなら再取得する。

receipt 本文は90日後に縮約し、ID・操作者・Workspace・正規化 request hash・結果 ID / revision・commit cursor は保持する（account削除は禁止）。再送前の resolve は staging を実行しない。縮約 receipt は該当 queue を ACK して正本取得を要求し、pull checkpoint を進めず後続編集を保持する。未処理 operation の ID・本文・base revision は変えず通常の409で競合を検出する。一律 rebase は行わず、明示的な Server version 採用だけを例外とする。Web も縮約結果から最新の正本を再取得する。

削除は初期無効の明示管理コマンドで日次実行し、通常リクエストには入れない。Server 時刻による90日超の履歴・本文だけを小分けに処理し、commit と同じ Workspace ロックを使う。migration、全 Server、対応クライアント、復帰検証、削除有効化の順とし、本番適用と scheduler 設定は別の運用操作にする。旧クライアントへ縮約結果を通常成功として返さず更新を要求する。会議データの保存期間は変えず、軽量 receipt が増え続けることは許容する。D1 はサポート対象外。過去の未リリース baseline 整理は、released migration の変更を許可する前例ではない。認証方式・proxy の user ID 変更は既存 permission を自動移行しない。

会議の削除は、親だけでなく summary / transcript / screenshot の canonical key も同じ transaction で無効化する。同じ会議 ID の削除・再作成が delta で集約されても、snapshot に退避された旧子データを再適用しない。

### 会議イベントと録音セッションの表示

Server の調査用履歴は `meeting_events` に保持する。会議の作成・メタデータ変更・削除は Server の確定 transaction 内で記録し、変更した項目名だけを残す。タグ名、変更前後の本文、音声、ファイルパスは対象外。Desktop は会議イベントを送らない。

`capabilities` は `meetingEvents: { version: 1 }` を返す。イベントは ID で冪等化し、履歴は Server だけに残す。開始・終了イベントから `recording_sessions` SQL view を構成し、未終了セッションがある会議を Web の一覧・詳細・サイドバーで録音中と表示する。生存通知や有効期限、状態カラムは持たない。終了情報が同期されるまで表示が残る。会議を削除すると、それ以前の開始イベントによる録音中表示は終了し、復旧しても再点灯しない。

イベント履歴は同期差分の90日保持とは独立し、期間削除や過去操作の補完は行わない。会議の論理削除時は復旧用に保持し、物理削除時に追加情報を除去して ID・種別・時刻だけを残す。Workspace 削除時は履歴も消す。調査は DB から行い、閲覧 API や専用 UI は持たない。

削除済み・無効・削除処理中の会議に届いた遅延イベントは `410 meeting_event_parent_unavailable` とする。履歴送信のために会議を復元しない。会議読取の録音判定は対象会議の開始・終了イベントを索引で検索し、他 Workspace の全履歴集計を避ける。

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

Desktop はスクリーンショットを撮影時に長辺1568px以下の WebP で保存し、それより前のローカル Workspace の画像も起動後に一度だけ同じ形式へ変換する。要約・OCR・キャプション・MCP には保存済み画像をそのまま渡す。1568px は Claude の標準解像度の上限で、Retina の画素を保存しても可読性は上がらず、エンコード時間と容量だけが増えるため。MCP に `image_size` 指定はない。チャットの添付画像は1280px上限とする。旧 `thumbnail` / 384px 経路は持たず、派生キャッシュの一括移行は行わない。撮影原本、サムネイル、リサイズ・書き出し時の再エンコードは品質80に統一する。Local Account は原本に加え、一覧で初めて表示したときに長辺480pxの `thumb_480` を品質80の JPEG で作り、端末内の file store にだけ `local/files/{fileId}/variants/v1/thumb_480.jpg` として保存する。2回目以降の一覧表示は原本を読まずにこれを使う。WebP は 480px の符号化に1枚約100 ms かかり、スクロール中の要求が直列に滞留するため使わない（JPEG は1 ms 未満、2026-11-20 計測）。この控えはバックアップの対象外で、原本を消す処理（`ScreenshotFileStore.remove`）が一緒に消す。要約前の選別もローカルでこの `thumb_480` を使い、Server と同じ解像度で判定する。保存は content provider の中で削除と同じ順序に並べ、削除後に書き戻さない。

### 画像解析の実行場所

Desktop の画像解析は Mac で実行する（[アカウント別 Desktop 推論](account-scoped-desktop-inference.md)）。Server の受理済み job の復旧・結果確定は [画像解析と受理済みジョブ](../server/search.md#画像解析と受理済みジョブ) に従う。

## Desktop のローカル保持

Desktop は Server の内容を端末に部分保持しない。本文・画像の取得、容量と最低保持期間による解放、同期状態の表示は削除した。

### ローカル参照と表示

UI の読み書きは `MeetingRepository` を通し、本文・要約・文字起こし・OCR は SQLite から読む。文字起こしは閲覧中の bounded window を再読込し、過去を読んでいる位置を末尾へ飛ばさない。サイドバー右のメイン領域のヘッダーに Workspace / Project の親階層 / 会議名を同じ文字サイズで表示する。各パンくずのプルダウンはホバーから0.3秒後に下向きに開く。Workspace のプルダウンには Workspace だけを表示し、配下の Project は混在させない。Project は同じ親を持つ Project、会議は同じ Project の会議へ移動できる。プルダウンの先頭にはリソース種別のラベルを表示する。パンくずの要素名を繰り返すツールチップは表示しない。プルダウン内のプロジェクト行は通常の文字色で表示し、クリックでプロジェクト詳細へ移動する。ホバーで右側へ配下のプロジェクトと会議を展開し、サブメニューが親の行のクリックを遮らないようにする。会議一覧は開いたときに20件ずつページング取得する。

Desktop のミーティング詳細は、固定ヘッダーと本文の間に 32pt の余白を設け、タイトル・メタデータ・タブ・本文を同じスクロール領域に置く。スクロール時はメイン領域と同じ背景色の固定ヘッダーの背後に内容が流れる。本文を中央寄せする幅制限はスクロール領域の内側へ適用し、縦スクロールバーはメイン領域の右端に表示する。文字起こしのページ読み込みと最新行への追従、スクリーンショット一覧の仮想化はスクロール所有者で維持する。ノートのエディターは本文に応じて高さを調整し、4096pt を超える長い文書だけ内部スクロールに切り替えて native viewport の高さを制限する。本文の保存・編集範囲は制限しない。

### テキスト本文

原文を `transcript_segment_bodies`、要約を `summary_bodies`、OCR / caption を `file_text_bodies` に分離する（`v42_localFirstSchema`）。本文テーブルは親 ID を主キー兼外部キーとし、原文と document は NOT NULL にする。OCR / caption がともに NULL の本文行は取得済みの値として扱う。metadata の Record は本文を持たず、本文を含む読取結果とは型を分ける。アプリの Repository と MCP は共通 `TextContentAccess` で完全性検査と本文取得を同じ SQLite 読取内で行う。`sync_content_state` に未完了と記録された本文（Server Workspace だった Workspace で取得前のもの）は取得できないものとして返し、空本文として扱わない。録音・バッチ結果・本文編集は metadata と本文を同じ transaction で確定する。

### 容量と最低保持期間

Desktop の本文・画像は解放しない。Server Account の本文の容量上限と最低保持期間の設定は同期とともに削除した。

## Documents 専用同期

明示公開した会議 Notes の同期・復元・presence は [Documents](documents.md) が定める。端末内 note は同期せず、MCP は read-only。本文更新は transaction キュー・receipt・pending による受信 defer の対象にせず、文書ごとの CRDT 差分 API と送信待ちで処理する。送信待ちでも受信をマージする。[独立した Document](document-identity.md) により文書は Workspace に属し、会議との関連は任意となる。会議の物理削除・reset は関連する文書を除去し、soft delete は関連する全用途の generation を更新して古い編集を拒否する。会議のない文書は Workspace のライフサイクルに従う。復元は新しいブロックの挿入とする。

- Web は100ms 固定窓で送信する。切断補完は2秒、flush は即時、親会議 ACK を先に待つ。Desktop の Notes は端末内だけに保存し、同期しない。

## Workspace の全内容移管

両 Workspace の Admin が Server に保存済みの全内容を移管する。Editor はこの操作を行えない。元の Workspace は空で残し、削除は別操作とする。

未同期データ自体は移管対象に含めない。ただし、Server が確認できる upload staging や未確定の処理を検知した場合は移管を拒否する。

移管は `POST /api/v1/workspaces/{workspace_id}/transfer` で両 Workspace を ID 順にロックし、一つの DB transaction で所属を更新する。ID・実体ファイルは維持する。元と先の revision を検証し、UUIDv7 の `Idempotency-Key` は所有者単位で保存する。同じ要求の再送は同じ Server 生成 ID を返し、異なる要求での再利用は409とする。

共有設定は移管先の設定を継承する。確認時には実際の閲覧者を組織・チーム所属から求め、閲覧できなくなる人と新しく閲覧できる人を表示する。確認時の閲覧者ハッシュを移管要求に含め、実行時に一致しなければ409で再確認を求める。PostgreSQL では確認から commit まで権限・組織所属・チーム所属の変更をテーブルロックで止める。

移管レシートに対象 ID を保持し、通常差分の期限切れ・元 Workspace の削除後も現在の所属を解決する。移管に関係した Workspace では、`X-Dahlia-Workspace-Transfers: 1` を送らない旧クライアントの差分・snapshot と書き込みを426で停止する。このヘッダーは対応能力の宣言であり、適用済み位置を表さない。

## 計測

外部 telemetry や内容・識別子の診断出力は加えない。

- Server 内部の `captureSyncTimings()` は明示的なローカル計測だけに使う。固定名フェーズと最大128件の時間だけをメモリに保持し、`stop()` で解除する。公開 HTTP API や環境変数、外部送信は持たない。`connectionAndBegin` にはプール取得と BEGIN の両方が含まれ、純粋なプール待ちではない。`transaction` は DB callback 内の処理全体で、個別の認可・lifecycle・domain・document・notes のロック待ちは別 interval とする。ロック待ちを処理時間へ二重加算しない。
- 再現用の使い捨て DB テスト: `sync-locks-postgres.test.ts`。`TEST_SYNC_LOCKS_DATABASE_URL` は別会議の並行更新・同一会議の競合・親削除・権限変更・公開順を、`TEST_SYNC_LOAD_DATABASE_URL` は10,000操作の単件／8件送信と通常編集の p95 を計測する。後者は wall clock の揺れを assertion にせず結果を記録する。
- store テストの計測値を、通信・描画込みの反映時間として扱わない。ユーザーの QA DB を測定のために初期化しない。

計測値（使い捨て DB でのローカル計測。ネットワーク・画像・transcript・実画面を含まず、新規編集の書き込み性能・QA のネットワーク・実画面の遅延の保証値ではない）:

| 日付 | 計測 | 結果 |
| --- | --- | --- |
| 2026-09-30 | 8,000背景要求に対する通常要求の選択位置 | 旧 FIFO の8,001番目から1番目。claim 6回は9.70〜10.46msで、4通常要求の後に背景要求を選択。送信完了までの時間ではない |
| 2026-09-30 | 短い文書の同一差分30回再送の transaction 内処理 p50/p95 | 通常4.42/4.71ms、同 Workspace の domain ロック保持中4.65/5.00ms |
| 2026-10-02 | 10,000 Project 作成 | 単件送信147.82秒、8件送信32.81秒。同一ホストで他の検証も実行中 |
| 2026-10-02 | 同じ Workspace の会議編集30件の p95 | 通常24.04ms、取込中31.00ms |

## 未適合・未検証

- Databricks Apps + Lakebase では 2026-09-02 に owner read/write、upload、Range、delete と RLS identity の非漏洩を確認した。全 deployment の検証済み宣言ではない。配置時には non-superuser / NOBYPASSRLS、FORCE RLS、同一 pinned connection での COMMIT / ROLLBACK 後の identity 非漏洩を fail-closed probe で確認し、失敗時は application-only 認可へ縮退しない。

## 却下した案

- PowerSync / Electric: 片方向 upload の段階では不要だったため採用していない。将来の全同期方式としての禁止ではない。
- 画像・transcript chunk・manifest を順に送り、backup restore 時に Server Workspace を削除して再送する owner-only upload: 双方向編集で履歴の欠落、競合、二重実行を防げないため、domain transaction と canonical delta にした。
- Workspace 単位の FIFO 送信と、blocked 以降の一括停止: 2026-09-30 の計測で、8,000件の背景要求があると通常要求は8,001番目に選ばれた。優先度と依存による送信にした。
- Workspace 内の全 domain 更新の排他: 重い本文更新が同じ Workspace の他の更新を待たせるため、対象 ID ごとのロックと短い publication 排他にした。

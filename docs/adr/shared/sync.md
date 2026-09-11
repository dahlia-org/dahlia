# Desktop / Server の canonical sync

対象: Desktop・Server・Private Web。採択: 2026-09-02〜09-03。API の詳細は [Server README](../../../apps/server/README.md)、ローカルの保存保証は [Architecture](../../../ARCHITECTURE.md) を参照する。

## 正本とアカウント境界

Server account の Vault / Project / meeting は Desktop と Web が共有する Server canonical record とし、Desktop の既存 SQLite 行を offline working copy にする。Local Account は独立して動作し、sync transaction を作らない。録音と確定文字起こしの保存はネットワークを待たない。

- サインインだけでは Local Vault を移さない。明示移行時に同じ Vault ID の存在を確認し、新規なら初期同期、既存 owner Vault なら通常の revision conflict 解決、member Vault なら Server version の採用だけを許可する。Server-managed Vault は常時同期し、別の同期 toggle は持たない。
- サインアウト前に local working copy を削除するか Local Account へ移す。どちらも Server record は残す。Local Account への移動では metadata 同期を完了し、全本文と不足する画像原本を先に揃え、ファイル参照の保存と queue、confirmed revision、cursor、接続関連の解除を同じ SQLite transaction で確定する。取得失敗時は接続と未送信データを保持する。
- export folder は任意の端末固有設定で、同期しない。未設定でも SQLite と同期データは利用でき、Markdown export / filesystem watch だけを無効にする。

## Server 保管庫の自動発見（2026-09-10）

Desktop は `GET /api/v1/vaults` で直接ユーザー共有・組織・チーム共有を含むサインイン済み接続の owner / member 保管庫を同期開始、foreground 復帰、定期同期、SSE 接続・通知時に発見し、設定での取り込みなしで一覧・同期対象にする。メタデータは自動同期し、本文・画像は既存の必要時取得を使う。初回同期前は空の保管庫と区別して表示する。所有者で絞る場合は `owner=user_…` を指定し、常に閲覧権限との積集合を返す。組織共有の `organizationId` は所有者とは別の条件として維持し、両者の併用は拒否する。
登録は接続を再検査する SQLite transaction で冪等に行い、確定 revision と作業コピーを同時に保存する。登録による upload は作らない。Server 所属 Vault は常に利用可能として表示し、Desktop の Vault 削除操作によるローカル登録解除は提供しない。Local Account の Vault 削除とサインアウト時のデータ処理は維持する。同一 ID の Local Vault や別接続の Vault は自動移行しない。既存の同期待ち操作、cursor、最終選択は維持する。通信失敗や一覧からの欠落だけでは削除せず、権限失効は既存の同期・データ保全経路で処理する。サインイン操作から Local Vault の移行確認は出さず、明示移行操作を使う。

## 同期対象とモデル

Vault 名・アイコン・色、2段階 Project 階層と名前・説明・アイコン・色、meeting metadata、summary document、transcript 原文、screenshot bytes / MIME / OCR / AI caption を同期する。翻訳文、SQLite ファイル、端末の export path は対象外。2026-09-07: 新規バッチ録音の結合音声は [専用の音声保管契約](recording-audio-archive.md) で追加した。note、tag、音声特徴量をこの同期契約へ追加しない。

2026-09-11: meeting のカレンダー情報に限り、`icalUid` / `recurrenceId` と `calendarEvent`（`start` / `end` / `is_all_day`）を同期対象に追加する。UID と recurrence ID はペアで扱い、単発予定の recurrence ID は空文字。更新での省略は Server の既存値を保持し、明示的な null は消去する。予定名・説明・参加者・URL と端末固有のカレンダー参照は対象外。Server のスナップショットは要約の XML context と入力変更検知に使用し、暗号化 Vault でも queryable metadata として保存する。

Desktop は受信した値（null を含む）を端末固有参照と別の working copy に保存し、通常更新・初期同期・復旧時の送信にはその値を使う。未受信の会議だけはローカル予定から初期化する。ローカル予定の開始・終了日時・終日フラグが変化した場合は、書き込み可能な Server Vault の同一予定に紐づく会議について、working copy の更新と送信キューへの記録を同じ SQLite transaction で確定する。Server で消去・別予定へ変更された識別子はローカル予定の再観測で戻さない。受信処理は送信キューを作らず、新しい未送信変更がある間は既存の receipt／delta 適用ガードを維持する。

Project は `app.projects` に置き Vault 権限を継承する。空 Vault と Project 単独変更も扱い、同じ Vault の meeting だけが参照できる。Project 削除前に依存 meeting を明示的に移動・解除し、依存が残る削除を Server が拒否する。Project は階層閲覧・明示 filter に使い、検索本文や vector へ混ぜない。

transcript の収録経路は `audio_source: mic | system`、人・diarization の話者は nullable `speaker_label` として分離する。既存 Desktop の収録経路は forward migration で移し、話者欄を空にする。未リリース時の旧 Server field の意味は互換経路を残さなかった。

## Transaction と競合

- `POST /api/v1/transactions` は1 Vault の operation 群を atomic commit する。UUIDv7 transaction ID を冪等キーとし、commit response を保存する。同じ ID と異なる内容の再利用は拒否する。
- Vault、Project、meeting metadata、summary は optimistic revision を使う。古い base revision は対象 entity と canonical record を含む `409` とし、暗黙の last-write-wins をしない。
- Desktop は local record と retry 用 snapshot を同じ SQLite transaction に書く。操作の追加 schema は `sync_transactions`（順序・lease・retry・block）、`sync_operations`（immutable JSON と独立した画像ファイル参照）、`sync_entity_state`（Server-confirmed revision のみ）、`sync_transcript_patch_items`（upsert / delete）で管理する。本文の保持状態は別の `sync_content_state` に保存し、expected / optimistic revision や pending/running の派生状態を重複保存しない。
- transcript patch と画像は bounded staging endpoint へ送り、その後に元の domain transaction を commit する。staging だけでは read surface に公開しない。全段階で現在の Vault 権限、ID、親子関係、hash、payload limit を検証する。
- local mutation は recorder を明示的に呼び、remote applier は呼ばない。receipt 反映時は新しい optimistic operation を上書きせず、confirmed revision と commit cursor の保存後に acknowledge 済み transaction を削除する。
- validation、revision conflict、authorization、transport failure は別状態で永続化する。自動 retry は transport error、408、425、429、5xx のみ。blocked transaction は同じ Vault の後続も止める。

worker は録音中も push / pull できるが、transcript patch は確定済み segment だけを queue に入れる。初期 snapshot は bounded SQLite write で録音へ実行機会を譲り、構築中に対象 Vault の録音や別 mutation が始まれば未送信の部分 snapshot を捨てて最新 working copy から再構築する。
録音による初期同期・復旧・本文置換の待機は対象 Vault 内だけで判定する。移動の反映では移動元と移動先を確認する。別の Local / Server Vault の録音には依存せず、録音待ちの Vault があっても他の Vault の初期 snapshot 構築を続ける。
初期 snapshot の原本取得が失敗した場合はその Vault のローカルデータを保持して失敗を報告し、他の Vault の snapshot 構築・送信・受信は続ける。明示的な競合解決では呼び出し元へ取得失敗を返す。

## 会議イベントと録音セッションの表示

2026-09-07: Server の調査用履歴は `meeting_events` に保持する。会議の作成・メタデータ変更・削除は Server の確定 transaction 内で記録し、変更した項目名だけを残す。Server Account の Desktop はタグ付与・解除、成功した録音開始、終了、音源ごとの物理セグメント切り替えを既存の永続 queue から送る。Local Account、タグ名、変更前後の本文、音声、ファイルパスは対象外。切り替えはファイル確定成功とは区別し、初回ファイル作成では発生させない。

`capabilities` の `meetingEvents: { version: 1 }` を確認した接続だけで送信を有効にする。イベントは ID で冪等化し、履歴は Server だけに残す。開始・終了イベントから `recording_sessions` SQL view を構成し、未終了セッションがある会議を Web の一覧・詳細・サイドバーで録音中と表示する。生存通知や有効期限、状態カラムは追加しない。終了情報が同期されるまで表示が残る。録音・保存はネットワークを待たず、他端末のセッションをローカルの録音テーブルへ適用しない。

イベント履歴は同期差分の90日保持とは独立し、期間削除や過去操作の補完は行わない。会議削除時は追加情報を除去し、ID・種別・時刻だけを残す。Vault・owner account 削除時は履歴も消す。調査はDBから行い、閲覧APIや専用UIは追加しない。

削除済み・無効・削除処理中の会議に届いた遅延イベントは `410 meeting_event_parent_unavailable` とし、Desktop はイベントだけの送信 transaction を破棄する。本文同期をブロックしたり、履歴送信のために会議を復元したりしない。会議読取の録音判定は対象会議の開始・終了イベントを索引で検索し、他 Vault の全履歴集計を避ける。

## Delta と削除

Server は Vault ごとの durable change ledger と opaque cursor を持つ。delta は high-water cursor を固定し、その境界までの各 entity の最終 canonical state をページングする。一時的な delete / recreate を露出しない。pull checkpoint は対応ページの適用時だけ進め、commit receipt の cursor で代用しない。

`GET /api/v1/events` は cursor だけの SSE invalidation。起動、foreground 復帰、再接続、イベント欠落は必ず delta API で追いつく。Web も同じ transaction endpoint を使い、同期データの Server MCP は read-only。OAuth と認可は [共通 OAuth](oauth.md) と [Vault permission](../server/database-and-identity.md#vault-permission) に従う。

原本は Vault 所有の `files`、会議との関係は独立 ID の `meeting_attachments` に保存する。`files` の基本項目は `uri`、`offset`（現在は0）、`size`、`content_type`、`checksum`（`SHA-256:` 接頭辞）とし、source / OCR / caption / 寸法は metadata に置く。source は作成時に固定し、metadata の部分更新は未指定キーを保持する。同じ Vault の複数会議で同じ file を共有でき、紐付けを解除しても原本を削除しない。参照が残る明示 file 削除は拒否する。

2026-09-09: [OpenAPI ADR](../server/openapi.md) により、JSON の `POST /api/v1/file-uploads` で ID・Vault・属性・MIME を予約し、`PUT /api/v1/file-uploads/{id}/content` へ octet-stream を送る。従前の単一 POST と query 属性形式は廃止する。最大64 MiB、Content-Length 検証、Server 側の streaming SHA-256、同一再送の成功・異内容409、Transaction 確定まで private staging という制約は保持する。
その後に `file` / `meeting_attachment` transaction で確定する。pending は通常の一覧から除外し、24時間後は再 upload を要求する。旧 upload API は残さず Desktop / Server を同時に切り替え、transaction schemaVersion 2 は維持する。
確定済み file の OCR / caption / 寸法は `PATCH /api/v1/files/{id}` でも更新できる。baseRevision と metadata の JSON 部分更新を受け付け、未指定キーを保持し、OCR / caption の null はクリアを表す。source と bytes は不変。metadata 更新は認可後に Server 内部で単一の `file:upsert` transaction を生成し、既存の競合検出・検索更新・durable delta を通す。Desktop は既存の永続 transaction queue を維持する。
原本 key は `files/{fileId}/original`、派生画像は `files/{fileId}/variants/v1/{variant}.webp`（`thumb_480` / `thumb_1280` / `thumb_1568` / `thumb_1920`）。新 File API は Databricks Volume に保存し、canonical URI は `/Volumes/.../files/{fileId}/original` とする。Artifact APIは2026-09-08に廃止した。既存 cloud file がないため旧 key migration は行わない。
原本とその HEAD は `/api/v1/files/{id}/content`、JSON metadata と metadata PATCH は `/api/v1/files/{id}` に分離する。公開 DTO は `contentType`、`contentUrl`、`ocrText` を使い、内部 URI / offset を返さない。DB の `uri` / `offset` / `content_type` / `ocr_text` は保存形式として維持し、境界で変換する。
GET / HEAD の原本と variant は Vault 認可、CSP sandbox、nosniff、Range を適用する。source は認可条件にしない。
File API の原本・variant は `private, no-cache` とし、クライアントは保存した画像の再利用前に現在の認可を再確認する。ETag が一致すれば304を返し、画像生成・ストレージ読込・画像転送を省略する。ただし `If-Unmodified-Since` も指定された場合は Range を除いた HEAD で日時条件を先に検証する。削除・権限失効後の要求は404を返すが、すでに画面に表示中の画像を消す通知は行わない。`Vary: Authorization, Cookie` で認証状態ごとのキャッシュを分ける。

## ローカル参照と画像の部分保持（2026-09-06）

Local / Server の両アカウントで UI の読み書きは既存 `MeetingRepository` を通す。保持済み本文・要約・文字起こし・OCR は SQLite から読み、
同期済み revision の観測で開いている会議の projection を更新する。文字起こしは閲覧中の bounded window を再読込し、
過去を読んでいる位置を末尾へ飛ばさない。会議タイトル横のアイコンとホバーヘルプで端末への保存と Server 同期完了、保留・復旧・競合を区別する。
アカウントメニューとフッターのアイコンは接続先に属する保管庫の同期状態を集約し、未完了・復旧・エラーがあれば同期済みより優先して表示する。右上のウィンドウヘッダーには同期状態を表示しない。

画像一覧は metadata だけを保持する。`ScreenshotContentProvider` が 移行待ちの旧 BLOB、共通ファイル、認証済み Server read を解決する。
delta / snapshot は画像ダウンロードを待たず metadata を適用する。Server Account の画像は未送信分と取得済み分を
Application Support/Dahlia/FileStore/server/{accountConnectionId}/files/{fileId}/original の同じ immutable file として管理する。画像行の `localReference` と送信 operation の
`attachmentReference` は独立して同じファイルを指すため、画像行を削除しても確定前の送信に必要な原本を保持できる。
撮影した原本を検証・確定した後、metadata と送信 operation を同じ SQLite transaction へ保存して完了を通知する。
Server は原本の削除待ちがある間、upload 完了の反映と file の確定を DB transaction 内で拒否する。同じ ID の再予約も削除完了後に原本を再送する。
現在の予約が有効で削除待ちだけが原因なら503で自動再試行し、予約自体が消えた場合の404とは区別する。
Server の staging upload 成功では保持を解除せず、同じ接続・Vault・hash の canonical revision と未処理 operation の参照を検査する。
未送信、再試行、競合、確定状態が不明な原本はキャッシュ容量の対象外とし、確定後はコピー・移動なしで削除可能となる。
添付のないメタデータ編集も含め、保留中の transaction がある Vault では取得済み原本を保持する。
receipt は後続の会議削除で消えた子を復元せず ACK し、Server の添付競合は欠損した親会議を返して明示的なローカル版の再適用で復旧できるようにする。
ファイル確定中とアカウント移動中は削除を止め、アプリの所有者だけが DB writer 内で参照を再検査して有界な件数を削除する。
取得済み画像の破損は再取得できるが、未送信画像の欠損・破損はエラーとして保持する。ファイルストアを開く処理や読み取りだけで画像を削除しない。
cache の追加・削除・破損回復は domain transaction と pull cursor を変更しない。

Server は一覧用の長辺最大480px（`thumb_480`）、1280px（`thumb_1280`）、プレビュー用1568px（`thumb_1568`）、1920px（`thumb_1920`）を長辺上限として、縦横比維持・拡大なし・WebP quality 80 で作る。Node は `sharp` を使用し、最初の参照時だけ生成して Volume に保存する。upload / commit では生成しない。変換は最大2並行で同じ画像・variant の処理を共有する。
生成や保存の失敗はエラーとし再試行できる。変換器を持たない環境は variant を広告しない。variant endpoint が原本を返すことはない。Web は1568px版を開き、原寸へのリンクも残す。コピー・書き出し・明示的な原寸取得は原本を使う。Server 内の AI 処理は HTTP 応答生成から分離した認可付き画像取得を再利用する。Desktop の要約・OCR・キャプション・チャット・MCP通常画像入力も長辺最大1280pxに統一する。未公開の旧 `thumbnail` / 384px 経路は残さず、派生キャッシュの一括移行は行わない。
撮影原本、サムネイル、リサイズ・書き出し時の再エンコードは品質80に統一する。
Local Account は原本だけを永続保存し、表示時の縮小デコードは既存メモリ cache / decode worker に任せる。

クラウド画像のファイル cache は全 Vault 合計で既定2 GiB、設定は1 / 2 / 5 / 10 GiB。LRU で上限超過時に80%まで戻し、
サムネイル用に20%を残す。未使用枠は原本も利用できる。ローカル原本、未送信原本、backup 世代はこの上限の対象外。
ファイルパスはアカウント接続 ID・file ID・生成 recipe で決め、索引に原本 hash と保持状態を記録する。
サムネイルは索引の原本 hash が現在の file と一致する場合だけ再利用し、旧索引の未記録項目や ID 再利用時は再取得する。会議や Vault の ID はパスに含めない。取得は最大4並行、不要な表示要求はキャンセルする。
書き込みは atomic とし、読込時に長さと hash を検証する。キャッシュが書けなくても取得した画像を表示できる。

MCP の画像参照は同じファイルストアを read-only で利用し、作成・削除は行わない。未取得の場合は起動中のアプリへ画像や不足本文を要求する同梱 helper 用 IPC を使い、
同じ OS ユーザーと同梱 helper executable を確認し、アプリ側でも Vault / 会議 / 画像の所属を検証する。token broker の権限は広げない。
未取得・破損画像をリストから黙って省かず、取得不能として返す。

未リリースの v45 は screenshots table を files と meeting_attachments に移し、既存画像 ID を両方の ID に引き継ぐ。旧 BLOB は file_migration_content へ退避し、ファイル検証後に解放する。operation の独立 attachment reference を追加する。
v44 以前の BLOB はファイルの検証と参照切り替えが成功した分だけ解放し、移行前の retry 用 BLOB 保護は維持する。
移行は起動時と同期前に再開でき、失敗時は元データを保持する。Local Account から Server への移動もファイルを準備し、
所属変更と参照の切り替えを同じ transaction で確定する。旧 v45 と旧 cache 形式は未リリースのため互換処理を持たない。
次の canonical metadata 取得で既存画像の Server 参照を確定する。解放した SQLite ページは次回起動時、録音開始前に空き容量を確認して
標準 `VACUUM` で回収し、以後は録音外で incremental vacuum を行う。失敗時は元の DB を維持して後の起動で再試行する。

## 経緯と未解決事項

初期の owner-only upload は画像・transcript chunk・manifest の順で転送し、backup restore 時に Server Vault を削除して再送していた。双方向編集では履歴の欠落、競合、二重実行を防げないため、domain transaction と canonical delta に変更した。PowerSync / Electric は初期の片方向 upload に不要だったため採用せず、その時点の判断を将来の全同期方式への禁止とは扱わない。

2026-09-02 の Databricks Apps + Lakebase の Phase 0 では owner read/write、upload、Range、delete と RLS identity の非漏洩を確認した。これは現在の全 deployment の検証済み宣言ではない。配置時には non-superuser / NOBYPASSRLS、FORCE RLS、同一 pinned connection での COMMIT / ROLLBACK 後の identity 非漏洩を fail-closed probe で確認し、失敗時は application-only 認可へ縮退しない。

保持方針は以下の90日契約で確定した。D1 の atomic batch 制約は [Server 検索の制限](../server/search.md#制限と運用条件) に残る。認証方式・proxy の user ID 変更は既存 permission を自動移行しない。過去の未リリース baseline 整理は、released migration の変更を許可する前例ではない。

## 90日保持と正本からの復帰（2026-09-06）

change ledger は同期専用として90日の差分復帰を保証し、それ以前と新規端末は正本 snapshot を取得する。Vault ごとの最新 sequence と削除済み境界を永続化し、境界更新と履歴削除を同一 transaction にする。delta の全ページが境界を検査し、期限切れは `410 sync_cursor_expired` とする。

snapshot は entity / ID の keyset pagination と開始 cursor を返す。複数リクエストを跨ぐ DB transaction は持たず、開始 cursor 以降の delta で追加・更新・削除を補正する。開始 cursor が期限切れなら再取得する。Desktop は内容を一時 SQLite に退避し、取得と補正の完了後に既存 remote applier で適用する。未送信 queue がある間は適用せず、編集・接続変更の永続 generation と録音状態を各適用 transaction で検査する。不一致なら削除照合・checkpoint 確定を保留する。内容書き込みはページで区切り、全体の内容をメモリに展開しない。Project と照合用 ID は既存 applier の metadata 集合を再利用する。

receipt 本文は90日後に縮約し、ID・owner・Vault・正規化 request hash・結果 ID / revision・commit cursor は既存アカウント削除契約まで保持する。再送前の resolve は staging を実行しない。縮約 receipt は該当 queue を ACK して正本取得を要求し、pull checkpoint を進めず後続編集を保持する。未処理 operation の ID・本文・base revision は変えず通常の409で競合を検出する。一律 rebase は行わず、既存の明示的 Server version 採用だけを例外とする。Web も縮約結果から最新の正本を再取得する。

削除は初期無効の明示管理コマンドで日次実行し、通常リクエストには入れない。Server 時刻による90日超の履歴・本文だけを小分けに処理し、commit と同じ Vault ロックを使う。migration、全 Server、対応クライアント、復帰検証、削除有効化の順とし、本番適用と scheduler 設定は別の運用操作にする。旧クライアントへ縮約結果を通常成功として返さず更新を要求する。会議データの保存期間は変えず、軽量 receipt が増え続けることは許容する。

会議の削除は、親だけでなく summary / transcript / screenshot の canonical key も同じ transaction で無効化する。同じ会議 ID の削除・再作成が delta で集約されても、snapshot に退避された旧子データを再適用しない。期限切れ後に owner Vault が存在しない場合は、残っている reset event と同じくローカル内容・録音を保持して confirmed sync state だけを解除する。member のローカルコピー削除は role を確認し、実際の行削除が成立した場合だけ退避音声の削除を確定する。


## テキスト本文の部分保持（2026-09-07）

metadata の全保持と本文の部分保持を分ける。`v46_textContent` で原文を `transcript_segment_bodies`、要約を `summary_bodies`、OCR / caption を `file_text_bodies` に分離し、`sync_content_state` に保持 revision、完全性、本文の存在・件数、検証 hash、UTF-8 byte 数、最終利用日時を記録する。本文テーブルは親 ID を主キー兼外部キーとし、原文と document は NOT NULL にする。未保持は本文行の不在で表し、空文字に変換しない。OCR / caption がともに NULL の本文行は取得済みの値として扱う。移行時の本文はすべて専用テーブルへ移し、Server の本文は未検証として残す。Server 観測 revision は既存 `sync_entity_state` が所有する。

metadata の Record は本文を持たず、本文を含む読取結果とは型を分ける。アプリの Repository と MCP は共通 `TextContentAccess` で完全性検査と本文取得を同じ SQLite 読取内で行い、呼び出し元の事前検査に依存しない。ページ取得でも会議全体の欠損を検出し、JOIN が欠損行を黙って除外しない。一覧・検索用の cached projection は明示した別の読取口を使う。録音・バッチ結果・本文編集は metadata、本文、同期 operation を従来の同じ transaction で確定する。

capabilities は `{ "sync": { "version": 4 }, "meetingEvents": { "version": 1 } }` のように機能別の対応 version を返す。`sync: { version: 4 }` は transaction schema 2、snapshot / delta 復旧、receipt 解決、metadata 同期と本文の個別取得を含む同期契約を表す。`meetingEvents: { version: 1 }` は会議イベントの受付契約を表す。entity revision や payload schema の version とは区別する。非対応の機能はフィールドを省略し、atomic sync 非対応の store は全機能を省いた `200 {}` を返す。認証・運用エラーは通常のエラーとして返す。クライアントは未知のフィールドを無視する。旧フィールドと旧ルートは維持しない。

`GET /api/v1/capabilities` の `sync: { version: 4 }` を確認する。snapshot / changes は常に meeting の重複 summary と検索用本文、summary document、file の OCR / caption、transcript 本文を省く。content query と contentMode response は廃止する。非対応では `updateRequired` を表示し、既存本文を保持して同期・解放を止める。transaction schema 2 は維持する。要約本文は既存の meeting 配下の summary/latest、文字起こしは meeting 配下の transcript/latest または transcript/{version} を使う。履歴番号 version と同期用 syncRevision は分離する。file は個別 metadata JSON から OCR / caption（nullable）と revision を1回で取得し、ID・Vault・checksum・同期済み revision と保存直前の編集保護を照合する。版が違えば通常同期後に1回再取得し、不一致や失敗では旧本文と未取得状態を保持する。依存取得は metadata のみ反映し、本文補完から confirmed revision を更新しない。不要となった text/file は削除する。

GET /files/{fileId} は原本、HEAD は同じ認可で原本の存在・HTTP header を確認する。HEAD は本文を送らず、各 storage の HEAD / stat を再利用する。アプリの metadata を独自 HTTP header に移さない。

対象 API はリリース前で後方互換性は不要。互換経路・fallback を残さず、Server / Web、次に Desktop の順で同じリリースとして切り替える。契約が異なる開発版同士は更新要求になる。DB migration と履歴保持方針の変更は不要。

`MeetingContentProvider` は SQLite を先に読み、古い完全な内容も stale として利用できる。明示操作・UI・AI・MCP は共通の保持 lease を使う。最大2取得を共有し、先読みは1枠まで、待機中の明示操作を優先する。文字起こしは一時 table に500件以下のページで取り込み、指定 revision、全体の件数・byte 数・hash を照合してから既存 remote applier の transaction で反映する。中断した一時行は掃除する。summary は会議単位、OCR / caption は共有 file 単位で取得する。本文 I/O は pull checkpoint と録音の永続保存を進めない・待たせない。

manifest hash は各 nullable UTF-8 field の `byteLength:bytes`、NULL は `-:` を SHA-256 に入力する。文字起こしは startTime / UUID 順の lowercase segment UUID と原文、summary は document、file は OCR の後に caption。UUID は本文 byte 数へ含めない。Swift / Server は共通 fixture で一致を検証する。既存本文の hash が同じなら本文 download を省くが、文字起こしの保持 revision が変わる場合は時刻・話者・音声ソースも取得してから revision を進める。同じ revision で内容が違えば元データを残して自動解放しない。

会話分析も共通 provider の lease で全文を確保し、Repository は未保持本文から空の分析を生成しない。本文の取得・revision 更新は表示中の分析を無効化し、計算結果の保存時にも完全性と保持 revision を確認する。録音後の分析は既存のバックグラウンド処理のまま実行する。

Local Account と未同期画像は端末解析 job の待機・処理・失敗表示を維持する。Server Account は capabilities API で `imageAnalysis: { version: 1 }` を確認した場合だけ端末解析を省略する。未対応・未設定の Server では端末解析を使い、同期済み画像の OCR / caption は端末 job の有無によらず共通 provider で取得する。

全 Server Account 合計128 MiBを超えると、再取得可能な検証済み本文を LRU で80%まで解放する。直近20会議は空き枠内だけ先読みする。閲覧済み本文を先読みのために追い出さず、解放した項目を次の先読みで取り直さない。Local Account、使用中、未送信・競合・復旧中の Vault、録音中は対象外。容量は本文だけを数え、metadata・翻訳・session・音声特徴量・ユーザーの Markdown・backup を含めない。解放は本文行だけを削除し、transcript metadata・summary header・file metadata と export 参照、端末固有属性を保持する。対応する FTS・旧 vector を除去し metadata 索引を再構築する。既存の起動時 VACUUM と録音外 incremental vacuum で空きページを回収する。

反映・解放 transaction は接続 ID / origin、Vault、mutation generation、対象の存在、revision、queue、復旧・録音状態を再検査する。権限・所属の変更は generation で進行中取得を失効させる。状態は missing / loading / failed / ready / stale / empty / deleted を区別し、失敗で完全な旧本文を消さない。

本文編集は完全性を検査し、操作の base revision は編集した保持 revision を使う。明示的なローカル版再適用だけが最新 revision を使える。未保持会議への録音追加は既存の durable write を使い、不足する過去本文を完全にしたと判定しない。Local Account への移動は metadata 同期、全本文・画像原本取得後に、各 Vault の Server high-water cursor が取得開始時の同期済み cursor と一致することを再確認する。不一致や通信失敗では移動を中止し、再試行時に同期と取得をやり直す。確定 transaction 内でも接続 generation・同期済み cursor・完全性を再検査する。失敗時は接続・queue・ローカル変更を保持する。

Server 版の採用や確定済み Vault の無効操作破棄では、破棄対象の本文だけを同じ transaction で通常の未保持表現へ解放し、Server revision が変わらなくても正本を再取得する。本文行を削除し、対応する FTS と開いている表示 projection も更新する。行・metadata・翻訳・音声特徴量は保持する。未確定 Vault の初期アップロード再構築と、明示的なローカル版再適用ではローカル本文を保持する。

## Server アカウント言語設定（2026-09-07）

出力言語と画像解析言語は Server DB を正本とし、Desktop は接続・認証 user ID に束縛したメモリだけで保持する。設定用ローカル table、競合制御用 revision、永続再送 queue は追加しない。Server の内部 revision は SSE 変更検知専用とする。初回 GET が未作成なら端末の現在値で conditional INSERT し、他端末の初期化を上書きしない。

起動・接続・再接続・画面表示と `account_settings` SSE invalidation で再取得する。取得をキャンセルし要求世代を照合して古い応答を捨てる。オフライン中は取得済み値か未取得状態を表示し、編集しない。再接続時の正本取得で通知欠落を回復する。Server Account の出力言語は要約と画像解析で共有する。要約の詳細度は方式共通とし、モデル・推論強度だけを方式別に保持する。設定の再取得ではモデル一覧を再取得せず、初回・接続変更・明示的な再読込み時だけ取得する。Web も account_settings 通知を購読して設定だけを再取得する。

設定取得と認証更新は録音開始・継続・停止の前提にしない。既存 working copy は設定未取得・期限切れ認証でもローカル録音と文字起こしを継続し、音声・確定文字起こし・画像・同期待ち操作を既存経路で保持する。再認証が必要なら同期だけを待機させる。新規サインインのオフライン対応は対象外。

## 録音中の通常差分適用（2026-09-07）

画像専用の最新 metadata 取得は撤回し、confirmed revision は通常同期が管理する。`RemoteChangePolicy` が通常差分・依存取得・指定 revision の本文反映の適用条件を共有する。送信待ち・送信中・競合停止中の操作と、現在および要求内の親子参照を検査する。録音中の transcript、会議や参照の削除、録音画像の原本差し替えを保護する。他の会議や競合しない OCR / caption 更新は録音だけを理由に止めない。Project 階層の整合は既存の snapshot 単位を維持する。

通常差分は保留があっても後続ページを読む。永続 cursor は保留のないページまでしか進めず、先読み cursor と high-water は実行中だけ保持する。次回・再起動後は永続 cursor から再取得し、同一 revision を再適用しない。SSE に加えて、送信 queue が空でなくても既存の5秒間隔の受信確認を行う。同一 DB / Vault の受信は transfer 用 worker とも重複させない。接続・復旧状態と mutation generation を適用時に再検査し、ACK と操作破棄でも generation を進めて保護解除前の応答を無効化する。

Server の差分は現在の正本を返し、削除は null revision を持つ。小さい数値 revision はそのまま上書きせず、削除・再作成が集約された可能性を既存の snapshot 復旧で確認する。復旧・reset は未送信操作や録音を保護する従来の一貫した適用単位を維持し、部分適用しない。参照が残る file の削除も保留して後続の参照削除を待つ。

`MeetingContentProvider` は要約・文字起こしの同期済み revision と manifest・件数・hash、file は個別 metadata の同期済み revision を検証して本文を反映し、metadata や confirmed revision は更新しない。表示中の OCR / caption は未完了または stale なら既存2秒間隔で確認する。完了条件は Server の解析判定と揃え、空の OCR は有効、caption は空白除去後に非空であることを要求する。Server の解析 job 状態は本文 API に含まれないため、5分で自動取得を停止し、取得済み本文を残して再取得操作を表示する。画像を開き直すか再取得すると待機を再開する。ネットワーク待機を録音・確定文字起こしの保存経路へ持ち込まず、本文の破棄・eviction は引き続き Vault 全体の未送信・復旧状態と録音状態で保護する。

### Transcript の生成日時と活動状態

Transcript UUID は生成元で確保して再送でも維持する。Server は `meeting_id` で meeting を参照し `(meeting_id, version)` を一意とする。`vault_id` は重複保持せず、子 segment の権限も meeting 経由で判定する。生成開始・終了確認は親の `started_at` / `ended_at`、初回 Server 保存は親の `created_at` とする。子の `started_at` / `ended_at` は従来どおり発話の絶対日時、`created_at` は確定テキストを生成した日時とする。子は確定テキストだけを保存する。

`status` は親の終了確認と子の作成日時から読み取り時に導出し、同期状態や録音状態と区別する。時刻だけでも変化するため同期 revision を増やさず、Web の期限タイマーと読み取り側の再計算で更新する。定義・既存 Desktop データの補完方針は [Audio and Transcription Data Flow](../../architecture/audio-transcription-data-flow.md#transcript-versions) に従う。

## Summary 世代と同期番号（2026-09-09）

Server の要約正本は `summaries` の最大 `version` とし、meeting に本文や最新ポインタを重複保存しない。世代は Vault lock 下で発番し、同期の `summary_revision` / `baseRevision` とは独立する。この変更を含む同期契約は capability `sync.version = 4` として判定する。latest の通信形式は `formatVersion`、世代は `version`、同期番号は `revision`。同期 entity ID は meeting ID のまま維持する。全履歴削除後は version を1から再開するが、同期 revision は継続する。receipt、競合応答、削除通知、Desktop の未送信編集保護と本文 hash 検証は維持する。

## 外観と運用スキーマの整理（2026-09-09）

Project / Vault の `icon`・`color` は nullable な正準フィールドとし、既存の ProjectIcon / ProjectThemeColor の保存値を使う。transaction で未指定の項目は保持し、null は設定解除。外観変更も通常の revision・競合検出・snapshot / delta の対象にする。Web と Desktop の編集 UI は同じフィールドを使い、子 Project は親の外観を継承する。子の独自外観は送信・保存せず、親から子への変更時には解除する。並行開発された `appearance` JSON 列は追加の移行で既存の `icon`・`color` を優先しながら未設定値を引き継ぎ、削除する。

Desktop の旧 `projectAppearances` UserDefaults は Vault を開いたときに DB へ移行する。Server 接続では確認済み owner の未設定 Project にだけ通常の transaction を記録し、未送信操作や競合を上書きしない。旧設定はローカル保存または送信確認まで保持する。Desktop 専用の `legacyAppearanceMigrated` は再移行を防ぐ印であり同期しない。競合解決で正本の未設定値を選んだ場合にも、旧設定を再適用しない。

## 保管庫の全内容移管（2026-09-09）

所有者が明示的に、自分の別の保管庫へ Server に保存済みの全内容をまとめて移管する。元の保管庫は空で残し、削除は別操作とする。リソースが残る保管庫の削除は拒否し、削除から暗黙に移管しない。

未同期データ自体は移管対象に含めない。ただし、実行時に未同期データを検知できる場合は移管を拒否する。Server が確認できる upload staging や未確定の処理と、Desktop が確認できるローカル送信待ちは区別する。Web からオフライン端末の送信待ちがないことは保証できず、検知できない状態を「同期済み」と表示しない。

移管は `POST /api/v1/vaults/{vault_id}/transfer` で両保管庫をID順にロックし、一つのDB transactionで所属を更新する。ID・実体ファイルは維持する。元と先のrevisionを検証し、UUIDv7の `Idempotency-Key` は所有者単位で保存する。同じ要求の再送は同じServer生成IDを返し、異なる要求での再利用は409とする。

ファイル・文字起こしのstaging受付と期限切れファイル予約の削除も、同じ保管庫ロックを取得してから行う。Desktopがresetの差分を複数ページ取得する場合は、全ページ取得後・適用直前にも移管を再確認し、途中で移管された会議やローカル録音を削除しない。

共有設定は移管先の設定を継承する。確認時には実際の閲覧者を組織・チーム所属から求め、閲覧できなくなる人と新しく閲覧できる人を表示する。確認時の閲覧者ハッシュを移管要求に含め、実行時に一致しなければ409で再確認を求める。PostgreSQLでは確認からcommitまで権限・組織所属・チーム所属の変更をテーブルロックで止める。

Desktopは移管を削除として適用しない。差分・snapshotの適用前に `GET /api/v1/vaults/{vault_id}/relocations` で既存IDの現在の所属と権限を確認し、必要な所属変更・参照・同期状態をローカルの一つのtransactionで更新する。録音の実体は変更しない。権限がない間、ローカル送信待ちのtransaction・録音アーカイブがある間、または移管する項目にローカル限定の組織・連絡先・参加者・インサイト・トピックとの参照がある間は、データと所属を保持して同期を停止する。権限復旧後は次の同期で再確認する。専用のバックアップ・破棄画面や、クライアントごとの移管履歴の適用位置・ACKは設けない。 送信の再試行では移管の送信待ち検査より先に既存のtransactionレシートを解決し、確定済みの処理を受領する。移管の確認・復旧に失敗しても、他の保管庫の受信と送信は継続する。

移管レシートに対象IDを保持し、通常差分の期限切れ・元保管庫の削除後も現在の所属を解決する。移管に関係した保管庫では、`X-Dahlia-Vault-Transfers: 1` を送らない旧クライアントの差分・snapshotと書き込みを426で停止する。このヘッダーは対応能力の宣言であり、適用済み位置を表さない。

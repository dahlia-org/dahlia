# Desktop / Server の canonical sync

対象: Desktop・Server・Private Web。採択: 2026-09-02〜09-03。API の詳細は [Server README](../../../apps/server/README.md)、ローカルの保存保証は [Architecture](../../../ARCHITECTURE.md) を参照する。

## 正本とアカウント境界

Server account の Vault / Project / meeting は Desktop と Web が共有する Server canonical record とし、Desktop の既存 SQLite 行を offline working copy にする。Local Account は独立して動作し、sync transaction を作らない。録音と確定文字起こしの保存はネットワークを待たない。

- サインインだけでは Local Vault を移さない。明示移行時に同じ Vault ID の存在を確認し、新規なら初期同期、既存 owner Vault なら通常の revision conflict 解決、member Vault なら Server version の採用だけを許可する。Server-managed Vault は常時同期し、別の同期 toggle は持たない。
- サインアウト前に local working copy を削除するか Local Account へ移す。どちらも Server record は残す。Local Account への移動では不足する画像原本を先に共通ファイルストアへ揃え、ファイル参照の保存と queue、confirmed revision、cursor、接続関連の解除を同じ SQLite transaction で確定する。取得失敗時は接続と未送信データを保持する。
- export folder は任意の端末固有設定で、同期しない。未設定でも SQLite と同期データは利用でき、Markdown export / filesystem watch だけを無効にする。

## 同期対象とモデル

Vault 名、2段階 Project 階層と名前・説明、meeting metadata、summary document、transcript 原文、screenshot bytes / MIME / OCR / AI caption を同期する。音声、翻訳文、SQLite ファイル、端末の export path は対象外。note、tag、calendar metadata、音声特徴量をこの同期契約へ追加しない。

Project は `app.projects` に置き Vault 権限を継承する。空 Vault と Project 単独変更も扱い、同じ Vault の meeting だけが参照できる。Project 削除前に依存 meeting を明示的に移動・解除し、依存が残る削除を Server が拒否する。Project は階層閲覧・明示 filter に使い、検索本文や vector へ混ぜない。

transcript の収録経路は `audio_source: mic | system`、人・diarization の話者は nullable `speaker_label` として分離する。既存 Desktop の収録経路は forward migration で移し、話者欄を空にする。未リリース時の旧 Server field の意味は互換経路を残さなかった。

## Transaction と競合

- `POST /api/v1/transactions` は1 Vault の operation 群を atomic commit する。UUIDv7 transaction ID を冪等キーとし、commit response を保存する。同じ ID と異なる内容の再利用は拒否する。
- Vault、Project、meeting metadata、summary は optimistic revision を使う。古い base revision は対象 entity と canonical record を含む `409` とし、暗黙の last-write-wins をしない。
- Desktop は local record と retry 用 snapshot を同じ SQLite transaction に書く。追加 schema は `sync_transactions`（順序・lease・retry・block）、`sync_operations`（immutable JSON と独立した画像ファイル参照）、`sync_entity_state`（Server-confirmed revision のみ）、`sync_transcript_patch_items`（upsert / delete）に限定する。expected / optimistic revision や pending/running の派生状態を重複保存しない。
- transcript patch と画像は bounded staging endpoint へ送り、その後に元の domain transaction を commit する。staging だけでは read surface に公開しない。全段階で現在の Vault 権限、ID、親子関係、hash、payload limit を検証する。
- local mutation は recorder を明示的に呼び、remote applier は呼ばない。receipt 反映時は新しい optimistic operation を上書きせず、confirmed revision と commit cursor の保存後に acknowledge 済み transaction を削除する。
- validation、revision conflict、authorization、transport failure は別状態で永続化する。自動 retry は transport error、408、425、429、5xx のみ。blocked transaction は同じ Vault の後続も止める。

worker は録音中も push / pull できるが、transcript patch は確定済み segment だけを queue に入れる。初期 snapshot は bounded SQLite write で録音へ実行機会を譲り、構築中に録音や別 mutation が始まれば未送信の部分 snapshot を捨てて最新 working copy から再構築する。
初期 snapshot の原本取得が失敗した場合はその Vault のローカルデータを保持して失敗を報告し、他の Vault の snapshot 構築・送信・受信は続ける。明示的な競合解決では呼び出し元へ取得失敗を返す。

## Delta と削除

Server は Vault ごとの durable change ledger と opaque cursor を持つ。delta は high-water cursor を固定し、その境界までの各 entity の最終 canonical state をページングする。一時的な delete / recreate を露出しない。pull checkpoint は対応ページの適用時だけ進め、commit receipt の cursor で代用しない。

`GET /api/v1/events` は cursor だけの SSE invalidation。起動、foreground 復帰、再接続、イベント欠落は必ず delta API で追いつく。Web も同じ transaction endpoint を使い、同期データの Server MCP は read-only。OAuth と認可は [共通 OAuth](oauth.md) と [Vault permission](../server/database-and-identity.md#vault-permission) に従う。

原本は Vault 所有の `files`、会議との関係は独立 ID の `meeting_files` に保存する。`files` の基本項目は `uri`、`offset`（現在は0）、`size`、`content_type`、`checksum`（`SHA-256:` 接頭辞）とし、source / OCR / caption / 寸法は metadata に置く。source は作成時に固定し、metadata の部分更新は未指定キーを保持する。同じ Vault の複数会議で同じ file を共有でき、紐付けを解除しても原本を削除しない。参照が残る明示 file 削除は拒否する。

`POST /api/v1/files` の予約、`PUT /api/v1/files/{id}/content` の最大64 MiBの immutable upload、`file` / `meeting_file` transaction の順に確定する。pending は通常の一覧から除外し、24時間後は再 upload を要求する。schemaVersion 2 へ Desktop / Web / Server を同時に切り替える。
原本 key は `files/{fileId}/original`、派生画像は `files/{fileId}/variants/v1/{variant}.webp`（`thumb_360` / `thumb_1280`）。新 File API は Databricks Volume に保存し、canonical URI は `/Volumes/.../files/{fileId}/original` とする。既存 Artifact API は変更しない。既存 cloud file がないため旧 key migration は行わない。
GET / HEAD の content と variant は Vault 認可、CSP sandbox、nosniff、Range を適用する。source は認可条件にしない。

## ローカル参照と画像の部分保持（2026-09-06）

Local / Server の両アカウントで UI の読み書きは既存 `MeetingRepository` を通す。本文・要約・文字起こし・OCR は SQLite に保持し、
同期済み revision の観測で開いている会議の projection を更新する。文字起こしは閲覧中の bounded window を再読込し、
過去を読んでいる位置を末尾へ飛ばさない。ヘッダーでは端末への保存と Server 同期完了、保留・復旧・競合を区別する。

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

Server は一覧用の長辺最大360px（`thumb_360`）と内容確認・AI入力用の長辺最大1280px（`thumb_1280`）を、縦横比維持・拡大なし・WebP quality 75 で作る。Node は `sharp` を使用し、最初の参照時だけ生成して Volume に保存する。upload / commit では生成しない。変換は最大2並行で同じ画像・variant の処理を共有する。
生成や保存の失敗はエラーとし再試行できる。変換器を持たない環境は variant を広告しない。variant endpoint が原本を返すことはない。Web は1280px版を開き、原寸へのリンクも残す。コピー・書き出し・明示的な原寸取得は原本を使う。Server 内の AI 処理は HTTP 応答生成から分離した認可付き画像取得を再利用する。Desktop の要約・OCR・キャプション・チャット・MCP通常画像入力も長辺最大1280pxに統一する。未公開の旧 `thumbnail` / 384px 経路は残さず、派生キャッシュの一括移行は行わない。
撮影原本、サムネイル、リサイズ・書き出し時の再エンコードは品質75に統一する。
Local Account は原本だけを永続保存し、表示時の縮小デコードは既存メモリ cache / decode worker に任せる。

クラウド画像のファイル cache は全 Vault 合計で既定2 GiB、設定は1 / 2 / 5 / 10 GiB。LRU で上限超過時に80%まで戻し、
サムネイル用に20%を残す。未使用枠は原本も利用できる。ローカル原本、未送信原本、backup 世代はこの上限の対象外。
ファイルパスはアカウント接続 ID・file ID・生成 recipe で決め、索引に原本 hash と保持状態を記録する。
サムネイルは索引の原本 hash が現在の file と一致する場合だけ再利用し、旧索引の未記録項目や ID 再利用時は再取得する。会議や Vault の ID はパスに含めない。取得は最大4並行、不要な表示要求はキャンセルする。
書き込みは atomic とし、読込時に長さと hash を検証する。キャッシュが書けなくても取得した画像を表示できる。

MCP の画像参照は同じファイルストアを read-only で利用し、作成・削除は行わない。未取得の場合は起動中のアプリへ画像だけを要求する専用 IPC を使い、
同じ OS ユーザーと同梱 helper executable を確認し、アプリ側でも Vault / 会議 / 画像の所属を検証する。token broker の権限は広げない。
未取得・破損画像をリストから黙って省かず、取得不能として返す。

未リリースの v45 は screenshots table を files と meeting_files に移し、既存画像 ID を両方の ID に引き継ぐ。旧 BLOB は file_migration_content へ退避し、ファイル検証後に解放する。operation の独立 attachment reference を追加する。
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

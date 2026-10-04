# 会議 Notes の共同編集 Documents 化

2026-09-30追記: Desktop の送信優先度・競合解決の範囲・通常受信の世代検査・文書送信間隔と Server のロックは、[優先同期 ADR](sync-priority.md) が該当する旧決定を置き換える。以下の旧仕様はこの範囲に限り履歴として残す。

採択: 2026-09-29。ユーザーが承認した実装計画に基づく。採択は実装・検証完了を意味しない。

## 正本と公開

会議 Notes を Tiptap / Yjs の文書へ置き換える。Server Workspace の共有文書は Server canonical、Desktop SQLite はオフライン作業コピー、Local Account は独立した正本とする。文書の識別・所属は [独立した Document](document-identity.md) で改訂した。文書 UUID は独立して発行し、公開 ID は `doc_` とする。会議との関連は任意で、会議 Notes のみ会議ごとに一意。Yjs checkpoint と更新ログが本文の正本であり、本文テキストとブロック一覧は派生物。別の `document_blocks` / `meeting_documents` 正本は作らない。

既存 Notes は自動公開しない。Local Account の既存本文は文字列・改行・日時を保って変換する。Server Workspace の旧 Notes は端末内に残し、Workspace 単位で対象と公開先を確認してから空の文書へ一度だけ取り込む。既存の共有本文との衝突では非公開コピーを保持し、人が判断する。旧 `notes` は今回削除しない。新しい共有 Notes と復元記録は Workspace の閲覧権限を継承する。未公開本文を共有要約に混ぜない。

## 同期と復元

文書の Yjs state／単一更新は8 MiBまでとする。初回更新に正本の全状態が含まれる場合も送信できるよう、専用 API の JSON request は24 MiB、Desktop の response 受信は32 MiBまでとし、既存 domain transaction の8 MiB上限は変更しない。復元履歴は本文を読み出す前にページ量を制限し、通常6 MiB以内で返す。単一の大きな記録は分割せず1件で返し、次ページへ進める。

本文の編集には CRDT 専用 API と文書ごとの独立した送信待ちを使う。既存の `/api/v1/transactions` によるドメイン更新契約の例外であり、文書障害で録音・文字起こし・要約の同期を止めない。送信待ちでも受信をマージする。Desktop の通常送信は最大2秒間隔で集約し、Web は下記の100ms集約を使い、再送は Yjs の冪等性を使う。編集ごとの永久 transaction receipt は追加しない。SSE は revision / cursor のみを通知し、再接続時は HTTP による差分交換で復旧する。

同じ段落への同時入力を許可し、排他ロックを設けない。段落の削除前と、受信マージで自身の編集が消える前の内容を復元用に保全し、通知する。ACK だけで未確認の復元用状態を破棄しない。復元は新しいブロックの挿入とし、文書全体を古い状態で置換しない。復元記録は自動期限削除せず、親の物理削除に従う。安定したブロック ID、分割・貼り付け時の新 ID、正本 worker による重複修復を共通コアで扱う。

文書の作成・削除・復元・移管・reset は会議と Workspace の認可・ライフサイクルに従い、遅延した編集で削除済みの親を復活させない。viewer は read-only。権限失効時の未送信編集を黙って破棄しない。presence は共有 DB に保存する5秒 heartbeat / 15秒 TTL のユーザー一覧で、本文や同期キューとは分離する。

会議を削除すると文書の送信世代を変更し、削除中の本文取得・更新と旧世代の送信を拒否する。利用者が会議を明示的に復元した後は、認可された最新 checkpoint を取得してから、新世代で未送信差分をマージする。Desktop と Web のエディタ・保存先は同じ Yjs の依存関係を保持し、保存先だけを空にしない。Workspace／Account をまたぐ未公開コピーの保全は、引き続き別の公開確認に従う。

## Runtime と保存

文書操作・差分集約・同期状態・復元判定は DOM / Node に依存しない TypeScript コアとする。保存、通信、時刻と乱数は host adapter で提供する。Web と Desktop WKWebView は共通 Tiptap エディタを使う。Desktop の JavaScriptCore は専用スレッドに隔離し、エディタ非表示でも同期できる。将来の Electron はこのコアとエディタを再利用し、renderer 外の SQLite adapter に接続する。

Desktop は差分と送信待ちを短い SQLite transaction で保存してから保存済みと通知する。本文生成・マージ・checkpoint 作成は MainActor と DB write transaction の外で行う。通常時250ms以内のローカル commit を目標とするが、強制終了前の未確認入力の保全時間は保証しない。録音停止に文書待機を追加しない。通常終了・画面切替はローカル commit だけを待つ。今回の Web はメモリのみで、閉じた後の未送信入力は復元保証の対象外。

本文・差分・復元記録・要約 snapshot は既存の Server 暗号化 store と RLS の対象。Notes の FTS / 検索 / Hindsight への直接取り込みは追加しない。再取得可能な共有文書キャッシュは既存128 MiB LRUへ含め、[Desktop の最低保持期間](sync.md#desktop-の最低保持期間2026-10-02)を優先して解放し、未送信・非公開・復元用・Local Account のデータは解放しない。バックアップ、移管、Server→Local、サインアウトで同じ保存境界を維持する。

## 要約

ジョブ受理時の共有 Notes の ID・revision・本文（存在しない状態も含む）を内部専用 `notesSnapshot` として暗号化保存する。現在の Notes を入力 fingerprint の再検査へ含めず、既存入力の変更検知は維持する。Notes を含めて2,000,000 UTF-16 code unitsの上限を適用し、XML escape した untrusted data として渡す。状態 API で snapshot 本文を返さない。

Desktop / Web の開始と明示的な `/retry` は編集を送り切ってから実行する。Server だけの開始では受理時の Server 状態を使う。同じジョブの自動再試行は同じ snapshot、新しい `/retry` ジョブは最新 snapshot を使う。既存ジョブには後付けしない。Server Workspace のローカル要約にも共有 Notes だけを含める。

## 配布と migration

Desktop v0.22.0 は v45、v0.23.0〜v0.24.1 は v46 まで配布済み。v1〜v46 の登録名・順序・処理と呼び出し先を保持し、新しい forward migration だけを追加する。旧文書の未配布という記述は過去の統合時点の記録である。Server は未リリースのため Drizzle baseline / snapshot / manifest を整合させて統合できるが、既存 DB の自動消去・履歴書換えはしない。

2026-09-30: ユーザー承認により未リリースの `v47_documents`〜`v51_scopedSyncReconciliation` を `v52_documentsAndSync` へ統合する。公開済み v0.24.2 の `v47_orphanedRecordingRecoveryState` と、それ以前の登録名・順序・処理・helper は維持する。新規DBと配布済みDBには最終 Documents schema を直接作成し、一時テーブルへのコピーを省く。GRDB の `merging` で旧開発版の適用状態を認識し、未適用処理だけを実行する。会議ID拘束が残る開発版だけは既存のデータ保持変換を行う。統合時にGRDBが置換するのは未リリース分の識別子だけで、配布済み履歴は変更しない。番号52は旧開発版バックアップのschema versionを下回らないために用いる。実DBへ手作業でledgerを書き換えたり、消去・再作成したりしない。旧開発版バックアップの検証専用に当時のschema生成処理を保持し、移行前の完全な構造・trigger検査を省略しない。通常のDB起動は統合migrationだけを使う。

Server / Web / Desktop を `sync.version = 7` へ一括更新し、`documents: { version: 1 }` を追加する。Node / Workers 共通で Documents を提供し、要約の runtime 対応範囲は維持する。TypeScript は当面 `apps/server` が所有し、既存 Vite / tsup で Desktop 同梱資材を生成する。root workspace は追加しない。2026-10-03 に Web と Electron の UI 共有のため、コア・エディタと資材生成は [`packages/ui`](../monorepo/dependencies.md) へ移り、root workspace を再導入した。生成物と依存の版は変えていない。

依存追加は `yjs`、`@tiptap/core`、`@tiptap/react`、`@tiptap/pm`、`@tiptap/starter-kit`、`@tiptap/extension-collaboration`、`@tiptap/extension-unique-id`、`@tiptap/y-tiptap`。バージョンを固定し、同梱ライセンスと生成物の再現性を検査する。

## 既存決定との関係と範囲

[sync](sync.md) の note 除外は旧端末内 Notes には維持し、明示公開した Documents には本 ADR の専用契約を適用する。[Server 要約](../server/summary-generation.md) のローカルメモ非送信は維持し、公開済み Documents の snapshot を入力へ追加する。[依存管理](../monorepo/dependencies.md) はアプリ単位を維持して生成資材を共有する。MCP / Agent の文書ツール、AI 書き込み、汎用文書一覧、Summary エディタ統合、カーソル共有、IndexedDB / PWA、Electron 本体は次段階。リリース・マージ・デプロイは今回の実装範囲外。

## 検証

Yjs の逆順・重複・オフライン再接続・削除競合・Undo / Redo / IME、ローカル commit と再起動、バックアップと移管、認可 / RLS / 暗号化、全要約開始経路と再試行を検証する。Desktop は公開タグ相当の v41 / v45 / v46 からの更新とバックアップ復元を確認する。Node / Workers / JavaScriptCore の共通 fixture、Desktop / Web の実画面、Swift build / 全テスト / lint、Server `pnpm check` を実行し、テスト件数を確認する。


## Web の変更駆動同期（2026-09-29 改訂）

Web は最初の編集から100msの固定窓でHTTP/Yjs差分を送信する。入力が続いても期限を延ばさず、送信中の追加編集はACK後の次便で送る。通常データのtransactionキューとは独立し、大量の文字起こし・添付同期の完了を待たない。presenceと復元履歴は5秒以上間隔の補助処理で、本文交換や保存表示を待たせない。flushは本文と未送信復元記録だけを待つ。Desktopの送信間隔は変更しない。

### タブ単位の同期通知

通常データと開いているNotesの通知は、タブごとの `GET /api/v1/events` 1本に集約する。`user` は期待する公開ユーザーID、`tab` はそのタブのランダム識別子（32桁の16進数）、`notes` は最大32件の `{workspaceId,meetingId}` をJSON文字列にしたものとする。サーバーは認証ユーザーを照合する。タブIDは認証情報でも他の接続を操作する権限でもない。

購読変更は旧接続を閉じ、対象一覧を付けた新しいHTTP GETで接続を置き換える。購読はその接続内にのみ存在し、変更APIやグローバルな可変購読レコードは作らない。同じtab値を別接続へ指定しても既存接続を変更・削除できないため、別ユーザー・別タブからの購読操作は成立しない。別Serverへ再接続してもsticky routingや共有購読テーブルは不要である。通常のEventSource自動再接続も同じ一覧を再送する。

クライアントは同じNotesの表示を参照カウントし、最後の表示を閉じると直ちに解除する。旧接続の遅延イベントは世代検査で無視する。アカウントの切替はAppの通常データ購読が所有し、遅れて完了した旧アカウントのNotes取得・復旧から現在の購読を置き換えない。再接続・再表示では購読を有効にしてから差分を読む。サーバーも購読開始後に全対象の現在revisionを返し、接続切替中の変更を回収する。会議IDで未作成Notesも購読し、存在確認だけで空文書を作らない。閉じたNotesの未送信編集・復元記録は購読とは別に保存・再送を続ける。

通常データは `invalidation`（opaque cursor）、Notesは `document`（公開Workspace/Meeting/Document ID、generation/revision cursor、unavailable）を送る。本文は含めず、文書ごとの最新位置へ合流する。Notesのイベントは通常データ用cursorを進めない。購読対象の権限をDB確認ごとに評価し、失効・削除時はunavailableを通知して解除する。表示が残っている場合は、認可されたHTTP同期が再び成功した時点で購読を再登録する。失敗した再試行や、閉じた表示に対する遅延応答では再登録しない。認証を5秒ごとに再検査し、切断時はlistenerとタイマーを解放する。AI本文ストリームは別用途として維持する。既存の文書別SSE APIは互換用に残すがWebは使用しない。

### 共通通知基盤と負荷

`sync/events` が通常データとNotesの起床を共通管理する。通常データのledger更新はstore transactionのcommit後、Notesは文書APIのcommit後に発行する。Node PostgreSQL/Lakebaseは既存pgの専用LISTEN接続1本と `dahlia_sync_changed` のNOTIFYを使う。通知は最大1024キー、1送信32キーで集約するヒントで、失敗しても保存済み編集のACKを失敗にしない。全インスタンスへの通知後も認可付き正本読み取りを必須とする。domainキーは全接続を起こすが、各接続が返すcursorはそのユーザーが読める範囲だけである。

- LISTEN稼働時: 通常データ・Notesとも通知で起床し、通知欠落を5秒ごとのDB確認で補完する。
- Workers/SQLite/LISTEN切断時: 通常データは2秒、開いているNotesは250msごとのDB確認で補完する。最大32件のNotesを1回の本文なし・認可付きSQLへまとめ、文書ごとのループを作らない。Notesが開いていなければ高速ループも作らない。
- Notesのみの起床では通常データcursorを毎回読まない。定常時の主要SQL数は高速補完のタブで約4回/秒＋通常データ約0.5回/秒、LISTEN正常時の無変更タブで各約0.2回/秒。これとは別に認証再検査、DB transaction/RLS設定、5秒以上間隔の補助処理がある。通知が続く場合は50msの合流窓でDB再検査頻度を有界にする。
- Webの本文HTTP補完は切断時の2秒間隔と未送信の再送だけにし、接続正常時の重複した本文pollをやめる。SSEの再接続では必ず最新差分を取得する。

Workers/HyperdriveはLISTEN/NOTIFYを使わず共有DBを確認する（[公式の非対応機能](https://developers.cloudflare.com/hyperdrive/reference/supported-databases-and-features/)）。Node受信・Workers書き込みの混在配置や通知送信だけが失敗した場合、Nodeは最大5秒の補完待ちになり得る。Workersも完全pushにする新インフラは追加しない。

`documents.accountBinding = true` のServerへは各文書HTTPに `X-Dahlia-Document-User` を付ける。認証後の不一致は409 `document_account_changed` とし未送信編集を保持する。未対応Serverでは従来のsession照合を残す。SSEのuser照合も認証の代用ではない。

### 測定範囲

ローカル20編集の統合通知測定（別BrowserDocument・タブ購読manager・SSEインスタンス、同一プロセスHTTP、共有SQLite接続、250ms補完）はp50 253ms、p95 259ms、最大290ms。ネットワーク、proxy buffering、背景タブ制限、ブラウザ描画、実端末・QA配置は未測定。p95 500msは改善目標で保証値ではない。別PostgreSQL pool間の通知とRLS、workerd上の別DB接続からの初回作成を統合SSEで検知する250ms補完経路も独立に検証する。

### 初回表示と表示書式の補正（2026-09-30）

Desktop の Documents は専用 URLSession の接続プールを持ち、domain SSE や大量添付転送による接続枠待ちを分離する。初回の checkpoint 取得で未送信編集がない場合は、その確定状態を直ちに表示し、冗長な差分交換を待たない。未送信編集がある場合は従来どおり交換と ACK を行う。復元履歴の取得は初回のエディタ表示を待たせない。会議の要約と文字起こしは既存の本文取得2枠で並行取得する。

段落の空行・余白、見出し、箇条書きのスタイルを `packages/ui/src/documents/editor.css`（当時は `apps/server/src/documents`）に共通化し、Web と Desktop 同梱資材の双方から使用する。改行を同期用本文へ再変換せず、Yjs のブロック構造を保持する。

### 段落内改行・貼り付け・ブロック移動（2026-10-01）

ユーザー要望により、Shift+Enter の段落内改行（Tiptap `hardBreak`）を有効にする。改行はブロックではなく段落内のインライン要素とし、共通コアの検証はブロック内に限って許可する。本文テキストでは `\n` になる。書式ツールバーは置かず、Markdown 入力規則とキーボードショートカットを使う。Desktop では編集可能な Notes にフォーカスしている間、⌘B は太字を切り替え、サイドバー開閉には使わない。

プレーンテキストの貼り付けは1行を1段落とし、空行を空の段落として残す。HTML のブロック間の `<br>`（Google Docs、VS Code など）は1行の空行として扱う。エディタ内のドラッグは内容をそのまま移す。

Notion と同様に、段落・見出し・リストの左のハンドルからブロックを移動できる。ハンドルは最上位ブロックだけを対象とし、箇条書き・番号付きリストは項目ではなくリスト全体を1ブロックとして移動する（2026-10-05 改訂）。ドロップ先も最上位ブロックの間に限り、ブロック間の挿入線で示す。ドロップ先はハンドル領域を含むエディタ全体でポインタの高さだけから決め、ブロックの上半分ならその上、下半分ならその下に入れる。挿入線は Web のテーマ色、Desktop のシステムアクセントカラーで太く描く。リスト内の項目の並べ替えは ⌘⇧↑/↓ で行う。本文または行の左のハンドル領域へ直接ホバーすると表示し、エディタ領域から離れると隠す。移動と同時の入力をその場に保つため、保存形式を以下の schemaVersion 2 に置き換える。

### ブロック移動と schemaVersion 2（2026-10-01）

ユーザー承認の案 B1 により、文書を `blocks`（ID → Y.Map）と `root`（最上位の子 ID の Y.Array）で保存する。前節までの XmlFragment、移動時の削除・再挿入、正本 worker の重複 ID 修復、50,000 ブロック上限は本節で置き換える。DB schema と依存の追加・削除は行わない。

ブロックは種類・属性・親 ID・生存フラグ・削除時刻をもつ。段落と見出しは同じ Y.Text を保持し、hardBreak は embed、書式は bold / italic / strike / code / underline / link とする。リストとリスト項目は子 ID の Y.Array を保持する。本文を書き直さず ID の順序と親だけを変更するので、移動・インデント・リスト間移動と同時の入力は移動先に残る。種類と属性は独立した CRDT レジスターなので、同時の「見出し → 段落」と「見出しレベル変更」で既知の古い属性が残る場合は、種類に必要な属性だけを表示する。未知の属性や不正な値は拒否する。

全 runtime の projection とエディタは同じ layout を使う。

- 親 ID を正本とし、別の親の配列に現れた ID は無視する。同じ配列の重複は最初だけを使う。
- 配列にない生存ブロックは ID 順に末尾へ置く。循環では最小 ID のリストをルート末尾へ切り離して表示する。
- リスト項目の先頭の見出しは段落として表示する。親が削除済み・不在の子、空リスト、先頭が段落・見出しではないリスト項目、ルートのリスト項目、深さ 64 を超えた部分は非表示にする。競合による非表示は保存拒否にせず、復元対象にする。
- 種類変更と移動では ID を保持する。分割の後半・貼り付けの重複には新 ID を振り、結合では前の ID を残す。

書き込みは最小のテキスト差分・書式差分と、LIS で安定した ID を残した順序差分へ変換する。移動した ID は元と移動先の配列から全出現を外して挿入する。連続する挿入はまとめ、大量貼り付けで配列の全コピーを ID ごとに繰り返さない。削除は `alive=false` と時刻の更新で、本文を残す。移動は既存ブロックを生存状態へ戻さない。

復元記録はマージ後・物理消去前の本文から作る。端末で追記して削除した更新が一緒に届いた場合も追記を含む全文を保全する。表示から消えた葉ブロックに加え、非表示のまま更新された非空の本文も記録する。復元は新しい段落の挿入で、古い全 checkpoint の再適用ではない。復元記録そのものは期限削除しない。

正本（Server、Local Account では Desktop）だけが以下を子孫ごと消去する。

- 親が存在しないブロック。親の消去後に届いた遅い作成も、復元記録を確保して回収する。
- 削除から既定 24 時間を経過した墓標。Server は `DAHLIA_DOCUMENT_DELETION_GRACE_HOURS`（0–8760 時間）で変更できる。
- 総数 6,000 または状態 6 MiB を超えた場合は、古い墓標から総数 5,000 以下かつ状態 5 MiB 以下になるまで（墓標がなくなれば終了）。

消去した ID だけを配列から除く。重複・別の親・まだ消去しない墓標の配列項目は、Undo で有効になるため修復しない。同時移動後に片側を Undo しても、もう片方の移動は残る。消去した削除は Undo できない。消去後に届いた編集や作成の Undo と競合した入力は、入力した端末の復元記録で保全する。削除時刻は端末時計なので、大幅な時計ずれは Undo 猶予を短くすることがある。

上限は表示 5,000 ブロック、墓標・非表示を含む総数 8,000、本文 2,000,000 UTF-16 単位、URL 8,192 文字、深さ 64、状態と単一更新 8 MiB。専用 request 24 MiB、Desktop 受信 32 MiB は維持する。エディタは変更前に件数・文字数・属性・容量を検査し、超過する変更を Y.Doc に書かない。容量は最後の実測に保守的な増分を加え、90% 付近で再実測する。セッションと Server でも検証するが、同時追加で上限を超えたリモート状態はクライアントが受信できる。旧 Notes の取り込みや復元の行数が多い場合は段落内改行にまとめ、CRLF・空行・末尾改行を含む文字列を保つ。

Server の消去が届くまでは、オフラインの墓標や削除直後の大きな本文のため新規入力を拒否する場合がある。容量圧力の閾値未満なら、同期しただけでは消去されず猶予期間も適用される。同時追加によって Server 上限を超えた後着差分は拒否され、未送信分は端末に残る。

エディタは y-prosemirror に依存せず、文書ごとのアダプタと Y.UndoManager を使う。通常の文字入力は単一ブロックだけを比較し、構造変更は ID で差分を取り出す。受信では layout を再計算し、変更ブロックと祖先だけを再構築して、最小の ProseMirror 差分を適用する。相対位置で選択範囲を保持する。IME 中の受信は描画を延期し、変換開始時の因果状態へローカル入力を書いて正本へマージする。変換中に対象が削除・物理消去された場合は、変更した葉の本文を因果 draft から既存の復元保存キューへ渡す。Desktop は差分と復元本文を同じローカル transaction で保存し、画面切替・保存再試行・権限喪失時の非公開退避でも両方を保持する。Undo はローカル origin のみを追跡し、ドラッグと ⌘⇧↑/↓ は共通の移動操作を使う。末尾段落の自動追加は無効にする。

Undo / Redo も変更前に検証する。リモートの追加で上限へ達した後に履歴から本文を戻す場合は、Undo 用の因果情報を含む一時コピーで結果を検証し、超過時は本体も履歴も変更しない。通常の文字入力ではこの全文コピーを行わない。

通常入力も、Desktop の50ms待ちや host 保存待ちの間に受信した削除と競合し得る。共通の受信処理は未確認のローカル編集がある場合、マージで消える本文を先に復元キューへ渡す。受信 checkpoint が編集側の clock を含んでいても、消去後に差分だけ受け取って本文を失った可能性があるため、復元判定を先に行う。未反映の clock が残る場合は確認待ちを維持し、本文を失わず host 確認できた編集は host 側の通常の復元経路に任せる。

未確認の編集がない受信では復元用の全文コピーを作らない。保存確認も、Yjs の struct と削除集合の両方が編集側に既知ならコピーを省く。Desktop と Web の host は、過去の編集履歴ではなく現在の未 ACK 更新で追加の競合復元を判定する。Desktop は checkpoint へ取り込んだ未送信更新も対象にし、判定と保存を同じ DB transaction で行う。Web の ACK は受信・保存と同じ順序キューを通す。

Desktop の未送信削除は Server 側での復元保存がまだ保証されないため、Server レプリカでも checkpoint を進める前に復元記録を保存する。復元と checkpoint は原子的に確定し、表示用の projectionSequence を復元済みの根拠にしない。これにより、未送信の末尾を残して Local Account へ移した場合や保存失敗後の再試行でも本文を保持する。
Web も未送信の削除本文を local append と同時に既存の復元キューへ渡し、送信より先に Server の消去が届いても保持する。

v1 の自動変換・互換読み取りは設けない。checkpoint / legacyUpdate は `unsupported_document_schema`（Server 422）、未解決の依存が残る差分は `invalid_document_update`（400）で拒否し、保存と ACK を行わない。旧文書・未送信差分・非公開コピーは残す。Desktop は旧形式専用の表示を行い、1 件の旧 archive が他の archive の一覧を止めない。旧 Notes の平文取り込みは v2 で生成する。`documents.version=2`、SharedDocument の `schemaVersion=2` とし、domain 同期の `sync.version=7` は変えない。

暗号化、RLS、世代・リビジョン、復元ページング、送信間隔、文書ロック、文書 ID・所属・再関連付けは維持する。collaboration 関連ライブラリは bundle と同梱ライセンスから外れるが、package.json / lockfile の依存削除は別途承認まで行わない。

#### メモリ測定範囲

`node --expose-gc --import tsx scripts/document-memory.ts --collect`（Node v26.3.0、2026-10-01）。表示 5,000、総数 8,000、本文 1,994,999 UTF-16 単位（日本語）、checkpoint 7,351,158 bytes で、送信側と受信側、前後の projection、復元・消去・再エンコードを保持した。開始時との差分 heap は GC 後最大 **79.8 MiB**、各段階の GC 前観測最大 **121.7 MiB**。段階間の明示 GC なしでは **164.8 MiB** の観測があり、GC 後の値は実行中ピークの保証ではない。Workers 実機の 128 MiB 内での動作は未検証であり、本測定だけで保証しない。スクリプトは合成データのみを扱う。

2026-10-01: ユーザー承認により未リリースの Documents・同期・共通背景ジョブを `v53_documentsSyncAndBackgroundJobs` の単一登録に統合する。v0.24.2 の v47 までの履歴とデータ保持処理は変更しない。旧開発版 v52 / v53 は GRDB merging で認識し、未適用の処理だけを実行する。検索ジョブはリリース済み DB に存在するため、共通キューへのデータ保持変換を維持する。

2026-10-02: 承認済みの修正計画に従い、Documents sync capability / request protocol を v3 に統一する。容量拒否は canonical を変更せず、accepted=false と canonical の差分を返す。未送信ログは保持し、後続の修正を含む現在の causal diff を再送し、取得時点の pending sequence のみ ACK する。Yjs schema v2 と domain sync v7 は維持する。Web の canonical / staging は Worker、Desktop は DB ごとに共有する専用 JSC thread が所有する。本文・layout は差分で更新し、通常 ACK は差分と vector の通知にする。復元検出済み sequence は projection / checkpoint と独立して永続化し、delta と復元コピーを同一 transaction に記録する。

復元履歴には document lock 下で割り当てる単調 sequence を導入する。同期は ascending の high-water cursor、表示は descending の独立した cursor とし、document / generation / mode / version を検証する。最大100件・保守的な6 MiBのページ（単独の大型コピーは例外）を使用する。Desktop は履歴と cursor を原子的に保存する。画面は1ページ・2,000文字のプレビューを保持し、全文は明示操作で開く。presence の5秒更新から履歴取得を分離する。

Server 未公開 baseline は最終 schema に直接更新する。Desktop は公開済み v0.24.2 の v47 までを変更せず、未公開 v52 / v53 と新しい復元 watermark / cursor を `v54_documentsSyncAndBackgroundJobs` に統合する。旧開発DBは GRDB merging と不足列の追加・必要な default のデータ保持変換で引き継ぐ。実DBの消去・手作業の migration ledger 編集は行わない。

通常の Desktop ingress / send / editor notification は常駐 runtime の処理済み位置から新しい SQLite delta だけを取得する。cache miss 時には checkpoint と永続ログ全体を再取得し、不完全な前提状態から開始しない。検出済みの復元コピーは durable recovery watermark が進むまで runtime に保持する。下書きの archive 前提は staging にだけ適用し、SQLite commit 後に canonical へ反映する。Web は Worker 障害に備え、main thread に index を持たない保存済み Yjs replica を delta で保持する。再起動時だけ snapshot を生成し、未保存の editor input を canonical に昇格しない。

2026-10-02: main の最低保持期間変更は Documents v54 の後の `v55_serverContentRetention` に配置する。未公開の旧 `v54_serverContentRetention` は merging で認識し、保持日時の再設定は行わない。旧 v53 / v54 の実スキーマから pending 更新・復元記録と外部キーの保持を検証する。

### Notes の状態表示（2026-10-04）

Desktop と Web は保存・同期状態、同期エラーを画面ヘッダーに表示する。詳細はヘッダーのポップオーバーで確認し、状態変化で本文の位置を動かさない。Web の未送信編集に対するタブ保持の案内とコピー操作もヘッダーから利用でき、別画面へ移動した後も保持する。復元履歴と未公開の旧 Notes は引き続き本文側で確認する。

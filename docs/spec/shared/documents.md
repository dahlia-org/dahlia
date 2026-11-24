# 会議 Notes の共同編集 Documents

採択: 2026-09-29。ユーザーが承認した実装計画に基づく。採択は実装・検証の完了を意味しない。

## 正本と公開

会議 Notes は Tiptap / Yjs の文書とする。Server Workspace の共有文書は Server が正本である。Desktop は Server と同期せず、Desktop SQLite の文書が正本である。文書の識別・所属は [独立した Document](document-identity.md) に従う。文書 UUID は独立して発行し、公開 ID は `doc_` とする。会議との関連は任意で、会議 Notes のみ会議ごとに一意とする。Yjs checkpoint と更新ログが本文の正本であり、本文テキストとブロック一覧は派生物である。別の `document_blocks` / `meeting_documents` 正本は持たない。

既存 Notes は自動公開しない。Desktop の既存本文は文字列・改行・日時を保って変換する。旧 `notes` は削除しない。共有 Notes と復元記録は Workspace の閲覧権限を継承する。未公開本文は共有要約に混ぜない。

## 同期と復元

文書の Yjs state／単一更新は8 MiBまでとする。専用 API の JSON request は24 MiBまでとする。既存 domain transaction の8 MiB上限は変えない。初回更新に正本の全状態が含まれる場合も、専用 API で送信できる。

本文の編集には CRDT 専用 API と文書ごとの独立した送信待ちを使う。これは既存の `/api/v1/transactions` によるドメイン更新契約の例外であり、文書の障害で録音・文字起こし・要約の同期を止めない。送信待ちでも受信をマージする。再送は Yjs の冪等性を使い、編集ごとの永久 transaction receipt は作らない。SSE は revision / cursor のみを通知し、再接続時は HTTP による差分交換で復旧する。送信間隔は [Documents 専用同期](sync.md#documents-専用同期) に従う。

同じ段落への同時入力を許可し、排他ロックは設けない。段落の削除前と、受信マージで自身の編集が消える前の内容を復元用に保全し、通知する。ACK だけで未確認の復元用状態を破棄しない。復元は新しいブロックの挿入とし、文書全体を古い状態で置換しない。復元記録は自動期限削除せず、親の物理削除に従う。安定したブロック ID と、分割・貼り付け時の新 ID を共通コアで扱う。

文書の作成・削除・復元・移管・reset は会議と Workspace の認可・ライフサイクルに従い、遅延した編集で削除済みの親を復活させない。viewer は read-only である。権限失効時の未送信編集は黙って破棄せず、保持する。presence は共有 DB に保存する5秒 heartbeat / 15秒 TTL のユーザー一覧で、本文や同期キューとは分離する。

会議を削除すると文書の送信世代を変更し、削除中の本文取得・更新と旧世代の送信を拒否する。利用者が会議を明示的に復元した後は、認可された最新 checkpoint を取得してから、新世代で未送信差分をマージする。Web のエディタと保存先は同じ Yjs の依存関係を保持し、保存先だけを空にしない。Workspace／Account をまたぐ未公開コピーの保全は、別の公開確認に従う。Desktop の会議の削除と復元は端末内の文書にだけ適用する。

容量拒否は canonical を変更せず、`accepted=false` と canonical の差分を返す。未送信ログは保持し、後続の修正を含む現在の causal diff を再送し、取得時点の pending sequence だけを ACK する（2026-10-02 承認の修正計画）。

### 復元履歴

復元履歴には document lock 下で割り当てる単調 sequence を持つ。同期は ascending の high-water cursor、表示は descending の独立した cursor とし、document / generation / mode / version を検証する。最大100件・保守的な6 MiB のページ（単独の大型コピーは例外）を使用する。復元検出済みの sequence は projection / checkpoint と独立して永続化し、delta と復元コピーを同一 transaction に記録する。Desktop は履歴と cursor を原子的に保存する。画面は1ページ・2,000文字のプレビューを保持し、全文は明示操作で開く。presence の5秒更新から履歴取得を分離する。

## Runtime と保存

文書操作・差分集約・同期状態・復元判定は DOM / Node に依存しない TypeScript コアとする。保存、通信、時刻と乱数は host adapter で提供する。Web と Desktop WKWebView は共通 Tiptap エディタを使う。Desktop の JavaScriptCore は DB ごとに共有する専用スレッドが所有し、エディタ非表示でも同期できる。コア・エディタ・Desktop 同梱資材の生成は [`packages/ui`](../../../packages/ui/AGENTS.md) が所有する。

Desktop は差分を短い SQLite transaction で保存してから保存済みと通知する。本文生成・マージ・checkpoint 作成は MainActor と DB write transaction の外で行う。通常時250ms以内のローカル commit を目標とするが、強制終了前の未確認入力の保全時間は保証しない。録音停止に文書の待機を加えない。通常終了・画面切替はローカル commit だけを待つ。Web は未送信入力をメモリにだけ保持し、閉じた後の未送信入力は復元保証の対象外とする。

本文・差分・復元記録・要約 snapshot は既存の Server 暗号化 store と RLS の対象とする。Notes の FTS・検索・保存メモリーへの直接取り込みは行わない。Desktop は Server の文書を保持しないので、Desktop の文書はすべて正本として解放しない。

通常の Desktop ingress / send / editor notification は、常駐 runtime の処理済み位置から新しい SQLite delta だけを取得する。cache miss 時には checkpoint と永続ログ全体を再取得し、不完全な前提状態から開始しない。検出済みの復元コピーは durable recovery watermark が進むまで runtime に保持する。下書きの archive 前提は staging にだけ適用し、SQLite commit 後に canonical へ反映する。Web は Worker 障害に備え、main thread に index を持たない保存済み Yjs replica を delta で保持する。再起動時だけ snapshot を生成し、未保存の editor input を canonical に昇格しない。

## 要約

ジョブ受理時の共有 Notes の ID・revision・本文（存在しない状態も含む）を内部専用 `notesSnapshot` として暗号化保存する。現在の Notes は入力 fingerprint の再検査に含めない。既存入力の変更検知は維持する。Notes を含めて 2,000,000 UTF-16 code units の上限を適用し、XML escape した untrusted data として渡す。状態 API で snapshot 本文を返さない。要約入力は対象会議の kind=notes の文書だけを選ぶ（[独立した Document](document-identity.md)）。

Desktop の要約は開始時に端末へ保存済みの Notes を使う。Web の開始と明示的な `/retry` は編集を送り切ってから実行する。Server だけの開始では受理時の Server 状態を使う。同じジョブの自動再試行は同じ snapshot を使い、新しい `/retry` ジョブは最新 snapshot を使う。既存ジョブには後付けしない。

## 配布と migration

Desktop v0.22.0 は v45、v0.23.0〜v0.24.1 は v46 まで配布済みである。v1〜v47 の登録名・順序・処理と呼び出し先を保持する。v47 は v0.24.2 で配布済みの `v47_orphanedRecordingRecoveryState` である。新しい migration は forward migration として追加する。

Documents・同期・共通背景ジョブの未公開 migration は `v54_documentsSyncAndBackgroundJobs` に統合されている。新規 DB と配布済み DB には最終 Documents schema を直接作成し、一時テーブルへのコピーは行わない。`v55_serverContentRetention` は `v54_documentsSyncAndBackgroundJobs` の後に置く。未公開の開発版 DB は GRDB の merging で認識し、未適用の処理だけを実行する。会議 ID 拘束が残る開発版は既存のデータ保持変換を行う。未公開の旧 `v54_serverContentRetention` は merging で認識し、保持日時を再設定しない。移行前に完全な構造・trigger 検査を省略しない。実 DB の消去と、手作業による migration ledger の編集は行わない。

検索ジョブはリリース済み DB に存在するため、共通キューへのデータ保持変換を維持する。

Server の未公開 baseline は最終 schema に直接更新する。既存 DB の自動消去・履歴の書き換えはしない。

Documents 同期の capability と request protocol はともに v3 とする（2026-10-02 ユーザー承認）。Yjs 文書の schema は v2 で、`SharedDocument.schemaVersion` は 2 とする。旧 Notes の平文取り込みは v2 で生成する。domain 同期の `sync.version` は [同期](sync.md) に従う。

TypeScript のコア・エディタ・資材生成は `packages/ui` が所有する（[依存管理](../monorepo/dependencies.md) はアプリ単位を維持し、生成資材を共有する）。依存は `yjs`、`@tiptap/core`、`@tiptap/react`、`@tiptap/pm`、`@tiptap/starter-kit`、`@tiptap/extension-collaboration`、`@tiptap/extension-unique-id`、`@tiptap/y-tiptap` で、バージョンを固定する。同梱ライセンスと生成物の再現性を検査する。collaboration 関連ライブラリは bundle と同梱ライセンスから外れる。package.json / lockfile からの依存削除は別途承認まで行わない。

## 既存決定との関係と範囲

[sync](sync.md) の note 除外は端末内 Notes に維持し、明示公開した Documents には本仕様の専用契約を適用する。[Server 要約](../server/summary-generation.md) のローカルメモ非送信は維持し、公開済み Documents の snapshot を入力へ追加する。

## 検証

変更時は次を検証する。Yjs の逆順・重複・オフライン再接続・削除競合・Undo / Redo / IME、ローカル commit と再起動、バックアップと移管、認可 / RLS / 暗号化、全要約開始経路と再試行。Desktop は v41 / v45 / v46 からの更新とバックアップ復元を確認する。旧 `v53` / `v54` の実スキーマから pending 更新・復元記録と外部キーの保持を検証する。Node / Workers / JavaScriptCore の共通 fixture と、Desktop / Web の実画面を確認する。

## Web の変更駆動同期

Web は最初の編集から100msの固定窓で HTTP/Yjs 差分を送信する。入力が続いても期限を延ばさず、送信中の追加編集は ACK 後の次便で送る。通常データの transaction キューとは独立し、大量の文字起こし・添付同期の完了を待たない。presence と復元履歴は5秒以上間隔の補助処理で、本文交換や保存表示を待たせない。flush は本文と未送信復元記録だけを待つ。Desktop の送信間隔は [Documents 専用同期](sync.md#documents-専用同期) に従う。

### タブ単位の同期通知

通常データと開いている Notes の通知は、タブごとの `GET /api/v1/events` 1本に集約する。`user` は期待する公開ユーザーID、`tab` はそのタブのランダム識別子（32桁の16進数）、`notes` は最大32件の `{workspaceId,meetingId}` をJSON文字列にしたものとする。サーバーは認証ユーザーを照合する。タブIDは認証情報でも他の接続を操作する権限でもない。

購読変更は旧接続を閉じ、対象一覧を付けた新しい HTTP GET で接続を入れ替える。購読はその接続内にのみ存在し、変更 API やグローバルな可変購読レコードは作らない。同じ tab 値を別接続へ指定しても既存接続を変更・削除できないため、別ユーザー・別タブからの購読操作は成立しない。別 Server へ再接続しても sticky routing や共有購読テーブルは不要である。通常の EventSource 自動再接続も同じ一覧を再送する。エラーのない旧接続を入れ替えるときは、最後に受け取った通常データ cursor を `cursor` に付け、Server はそれより後の変更だけを `invalidation` で通知する。この入れ替えは再接続として扱わず、通常データを全件読み直さない。初回接続とエラー後の接続では全件を読み直す。

クライアントは同じ Notes の表示を参照カウントし、最後の表示を閉じると直ちに解除する。旧接続の遅延イベントは世代検査で無視する。Web のアカウントの切替は App の通常データ購読が所有し、遅れて完了した旧アカウントの Notes 取得・復旧から現在の購読を置き換えない。再接続・再表示では購読を有効にしてから差分を読む。サーバーも購読開始後に全対象の現在 revision を返し、接続切替中の変更を回収する。会議 ID で未作成の Notes も購読し、存在確認だけで空文書を作らない。閉じた Notes の未送信編集・復元記録は購読とは別に保存・再送を続ける。

通常データは `invalidation`（opaque cursor）、Notes は `document`（公開 Workspace/Meeting/Document ID、generation/revision cursor、unavailable）を送る。本文は含めず、文書ごとの最新位置へ合流する。Notes のイベントは通常データ用 cursor を進めない。購読対象の権限を DB 確認ごとに評価し、失効・削除時は unavailable を通知して解除する。表示が残っている場合は、認可された HTTP 同期が再び成功した時点で購読を再登録する。失敗した再試行や、閉じた表示に対する遅延応答では再登録しない。認証を5秒ごとに再検査し、切断時は listener とタイマーを解放する。AI 本文ストリームは別用途として維持する。既存の文書別 SSE API は互換用に残すが、Web は使用しない。

### 共通通知基盤と負荷

`sync/events` が通常データと Notes の起床を共通管理する。通常データの ledger 更新は store transaction の commit 後、Notes は文書 API の commit 後に発行する。Node PostgreSQL/Lakebase は既存 pg の専用 LISTEN 接続1本と `dahlia_sync_changed` の NOTIFY を使う。通知は最大1024キー、1送信32キーで集約するヒントで、失敗しても保存済み編集の ACK を失敗にしない。全インスタンスへの通知後も認可付き正本読み取りを必須とする。domain キーは全接続を起こすが、各接続が返す cursor はそのユーザーが読める範囲だけである。

- LISTEN 稼働時: 通常データ・Notes とも通知で起床し、通知欠落を5秒ごとの DB 確認で補完する。
- Workers / SQLite / LISTEN 切断時: 通常データは2秒、開いている Notes は250msごとの DB 確認で補完する。最大32件の Notes を1回の本文なし・認可付き SQL へまとめ、文書ごとのループを作らない。Notes が開いていなければ高速ループも作らない。
- Notes のみの起床では通常データ cursor を毎回読まない。定常時の主要 SQL 数は、高速補完のタブで約4回/秒＋通常データ約0.5回/秒、LISTEN 正常時の無変更タブで各約0.2回/秒。これとは別に認証再検査、DB transaction / RLS 設定、5秒以上間隔の補助処理がある。通知が続く場合は50msの合流窓で DB 再検査頻度を有界にする。
- Web の本文 HTTP 補完は切断時の2秒間隔と未送信の再送だけにし、接続正常時の重複した本文 poll はしない。SSE の再接続では必ず最新差分を取得する。

Workers / Hyperdrive は LISTEN/NOTIFY を使わず共有 DB を確認する（[公式の非対応機能](https://developers.cloudflare.com/hyperdrive/reference/supported-databases-and-features/)）。Node 受信・Workers 書き込みの混在配置や通知送信だけが失敗した場合、Node は最大5秒の補完待ちになり得る。Workers も完全 push にする新インフラは追加しない。

`documents.accountBinding = true` の Server へは各文書 HTTP に `X-Dahlia-Document-User` を付ける。認証後の不一致は 409 `document_account_changed` とし、未送信編集を保持する。未対応 Server では従来の session 照合を残す。SSE の user 照合も認証の代用ではない。

### 測定範囲

ローカル20編集の統合通知測定（別 BrowserDocument・タブ購読 manager・SSE インスタンス、同一プロセス HTTP、共有 SQLite 接続、250ms 補完）は p50 253ms、p95 259ms、最大290ms。ネットワーク、proxy buffering、背景タブ制限、ブラウザ描画、実端末・QA 配置は未測定である。p95 500ms は改善目標で保証値ではない。別 PostgreSQL pool 間の通知と RLS、workerd 上の別 DB 接続からの初回作成を統合 SSE で検知する250ms補完経路も、独立に検証する。

### 初回表示と表示書式

Desktop の復元履歴の取得は初回のエディタ表示を待たせない。

段落の空行・余白、見出し、箇条書きのスタイルを `packages/ui/src/documents/editor.css` に共通化し、Web と Desktop 同梱資材の双方から使用する。改行を同期用本文へ再変換せず、Yjs のブロック構造を保持する。

### 段落内改行・貼り付け・ブロック移動

Shift+Enter の段落内改行（Tiptap `hardBreak`）を有効にする（2026-10-01、ユーザー要望）。改行はブロックではなく段落内のインライン要素とし、共通コアの検証はブロック内に限って許可する。本文テキストでは `\n` になる。書式ツールバーは置かず、Markdown 入力規則とキーボードショートカットを使う。Desktop では編集可能な Notes にフォーカスしている間、⌘B は太字を切り替え、サイドバー開閉には使わない。

プレーンテキストの貼り付けは1行を1段落とし、空行を空の段落として残す。HTML のブロック間の `<br>`（Google Docs、VS Code など）は1行の空行として扱う。エディタ内のドラッグは内容をそのまま移す。

Notion と同様に、段落・見出し・リストの左のハンドルからブロックを移動できる。ハンドルは最上位ブロックだけを対象とし、箇条書き・番号付きリストは項目ではなくリスト全体を1ブロックとして移動する。ドロップ先も最上位ブロックの間に限り、ブロック間の挿入線で示す。ドロップ先はハンドル領域を含むエディタ全体でポインタの高さだけから決め、ブロックの上半分ならその上、下半分ならその下に入れる。挿入線は Web のテーマ色、Desktop のシステムアクセントカラーで太く描く。リスト内の項目の並べ替えは ⌘⇧↑/↓ で行う。ハンドルは本文または行の左のハンドル領域へ直接ホバーすると表示し、エディタ領域から離れると隠す。

### ブロック構造と schemaVersion 2

文書は `blocks`（ID → Y.Map）と `root`（最上位の子 ID の Y.Array）で保存する（2026-10-01、ユーザー承認の案 B1）。XmlFragment による本文保存、移動時の削除・再挿入、50,000 ブロック上限は持たない。

ブロックは種類・属性・親 ID・生存フラグ・削除時刻をもつ。段落と見出しは同じ Y.Text を保持し、hardBreak は embed、書式は bold / italic / strike / code / underline / link とする。リストとリスト項目は子 ID の Y.Array を保持する。本文を書き直さず ID の順序と親だけを変更するので、移動・インデント・リスト間移動と同時の入力は移動先に残る。種類と属性は独立した CRDT レジスターなので、同時の「見出し → 段落」と「見出しレベル変更」で既知の古い属性が残る場合は、種類に必要な属性だけを表示する。未知の属性や不正な値は拒否する。

全 runtime の projection とエディタは同じ layout を使う。

- 親 ID を正本とし、別の親の配列に現れた ID は無視する。同じ配列の重複は最初だけを使う。
- 配列にない生存ブロックは ID 順に末尾へ置く。循環では最小 ID のリストをルート末尾へ切り離して表示する。
- リスト項目の先頭の見出しは段落として表示する。親が削除済み・不在の子、空リスト、先頭が段落・見出しではないリスト項目、ルートのリスト項目、深さ 64 を超えた部分は非表示にする。競合による非表示は保存拒否にせず、復元対象にする。
- 種類変更と移動では ID を保持する。分割の後半・貼り付けの重複には新 ID を振り、結合では前の ID を残す。

書き込みは最小のテキスト差分・書式差分と、LIS で安定した ID を残した順序差分へ変換する。移動した ID は元と移動先の配列から全出現を外して挿入する。連続する挿入はまとめ、大量貼り付けで配列の全コピーを ID ごとに繰り返さない。削除は `alive=false` と時刻の更新で、本文を残す。移動は既存ブロックを生存状態へ戻さない。

復元記録はマージ後・物理消去前の本文から作る。端末で追記して削除した更新が一緒に届いた場合も追記を含む全文を保全する。表示から消えた葉ブロックに加え、非表示のまま更新された非空の本文も記録する。復元は新しい段落の挿入で、古い全 checkpoint の再適用ではない。復元記録そのものは期限削除しない。

正本（Server Workspace では Server、Desktop では Desktop）だけが以下を子孫ごと消去する。

- 親が存在しないブロック。親の消去後に届いた遅い作成も、復元記録を確保して回収する。
- 削除から既定 24 時間を経過した墓標。Server は `DAHLIA_DOCUMENT_DELETION_GRACE_HOURS`（0–8760 時間）で変更できる。
- 総数 6,000 または状態 6 MiB を超えた場合は、古い墓標から総数 5,000 以下かつ状態 5 MiB 以下になるまで（墓標がなくなれば終了）。

消去した ID だけを配列から除く。重複・別の親・まだ消去しない墓標の配列項目は、Undo で有効になるため修復しない。同時移動後に片側を Undo しても、もう片方の移動は残る。消去した削除は Undo できない。消去後に届いた編集や作成の Undo と競合した入力は、入力した端末の復元記録で保全する。削除時刻は端末時計なので、大幅な時計ずれは Undo 猶予を短くすることがある。

上限は、表示 5,000 ブロック、墓標・非表示を含む総数 8,000、本文 2,000,000 UTF-16 単位、URL 8,192 文字、深さ 64、状態と単一更新 8 MiB である。専用 request 24 MiB は維持する。エディタは変更前に件数・文字数・属性・容量を検査し、超過する変更を Y.Doc に書かない。容量は最後の実測に保守的な増分を加え、90% 付近で再実測する。セッションと Server でも検証するが、同時追加で上限を超えたリモート状態はクライアントが受信できる。旧 Notes の取り込みや復元の行数が多い場合は段落内改行にまとめ、CRLF・空行・末尾改行を含む文字列を保つ。

Server の消去が届くまでは、オフラインの墓標や削除直後の大きな本文のため新規入力を拒否する場合がある。容量圧力の閾値未満なら、同期しただけでは消去されず猶予期間も適用される。同時追加によって Server 上限を超えた後着差分は拒否され、未送信分は端末に残る。

エディタは y-prosemirror に依存せず、文書ごとのアダプタと Y.UndoManager を使う。通常の文字入力は単一ブロックだけを比較し、構造変更は ID で差分を取り出す。受信では layout を再計算し、変更ブロックと祖先だけを再構築して、最小の ProseMirror 差分を適用する。相対位置で選択範囲を保持する。IME 中の受信は描画を延期し、変換開始時の因果状態へローカル入力を書いて正本へマージする。変換中に対象が削除・物理消去された場合は、変更した葉の本文を因果 draft から既存の復元保存キューへ渡す。Desktop は差分と復元本文を同じローカル transaction で保存し、画面切替・保存再試行・権限喪失時の非公開退避でも両方を保持する。Undo はローカル origin のみを追跡し、ドラッグと ⌘⇧↑/↓ は共通の移動操作を使う。末尾段落の自動追加は無効にする。

Undo / Redo も変更前に検証する。リモートの追加で上限へ達した後に履歴から本文を戻す場合は、Undo 用の因果情報を含む一時コピーで結果を検証し、超過時は本体も履歴も変更しない。通常の文字入力ではこの全文コピーを行わない。

通常入力も、Desktop の50ms待ちや host 保存待ちの間に受信した削除と競合し得る。共通の受信処理は未確認のローカル編集がある場合、マージで消える本文を先に復元キューへ渡す。受信 checkpoint が編集側の clock を含んでいても、消去後に差分だけ受け取って本文を失った可能性があるため、復元判定を先に行う。未反映の clock が残る場合は確認待ちを維持し、本文を失わず host 確認できた編集は host 側の通常の復元経路に任せる。

未確認の編集がない受信では復元用の全文コピーを作らない。保存確認も、Yjs の struct と削除集合の両方が編集側に既知ならコピーを省く。Web の host は、過去の編集履歴ではなく現在の未 ACK 更新で追加の競合復元を判定し、ACK を受信・保存と同じ順序キューに通す。Desktop は削除の復元の判定と保存を checkpoint と同じ DB transaction で行う。

Desktop は checkpoint を進める前に削除した本文の復元記録を保存する。復元と checkpoint は原子的に確定し、表示用の projectionSequence を復元済みの根拠にしない。これにより、保存失敗後の再試行でも本文を保持する。Web は未送信の削除本文を local append と同時に既存の復元キューへ渡し、送信より先に Server の消去が届いても保持する。

v1 の自動変換・互換読み取りは設けない。checkpoint / legacyUpdate は `unsupported_document_schema`（Server 422）、未解決の依存が残る差分は `invalid_document_update`（400）で拒否し、保存と ACK を行わない。旧文書・未送信差分・非公開コピーは残す。Desktop は旧形式専用の表示を行い、1件の旧 archive が他の archive の一覧を止めない。

暗号化、RLS、世代・リビジョン、復元ページング、送信間隔、文書ロック、文書 ID・所属・再関連付けは維持する。

#### メモリ測定範囲

`node --expose-gc --import tsx scripts/document-memory.ts --collect`（Node v26.3.0、2026-10-01）。表示 5,000、総数 8,000、本文 1,994,999 UTF-16 単位（日本語）、checkpoint 7,351,158 bytes で、送信側と受信側、前後の projection、復元・消去・再エンコードを保持した。開始時との差分 heap は GC 後最大 **79.8 MiB**、各段階の GC 前観測最大 **121.7 MiB**。段階間の明示 GC なしでは **164.8 MiB** の観測があり、GC 後の値は実行中ピークの保証ではない。Workers 実機の 128 MiB 内での動作は未検証であり、本測定だけで保証しない。スクリプトは合成データのみを扱う。

### Notes の状態表示

Desktop は保存状態と保存エラーを、Web は保存・同期状態と同期エラーを画面ヘッダーに表示する。詳細はヘッダーのポップオーバーで確認し、状態変化で本文の位置を動かさない。Web の未送信編集に対するタブ保持の案内とコピー操作もヘッダーから利用でき、別画面へ移動した後も保持する。復元履歴と未公開の旧 Notes は本文側で確認する。

## 却下した案

- XmlFragment による本文保存と、移動時の削除・再挿入による並べ替え: 本文を書き直さず ID の順序と親だけを変更するため、移動・インデント・リスト間移動と同時の入力が移動先に残る。
- Notes の FTS・検索・保存メモリーへの直接取り込み: 元の記録に理由の記載はない。

## 未適合・未検証

- 未実装: MCP / Agent の文書ツール、AI による書き込み、汎用文書一覧、Summary エディタ統合、カーソル共有、IndexedDB / PWA、Electron 本体。
- 未検証: Workers 実機の 128 MiB 内での動作。
- 未検証: 実端末・QA 配置での反映時間。ネットワーク・proxy・背景タブ・ブラウザ描画は未測定。
- 未確定: ローカル20編集の統合通知測定（p50 253ms、p95 259ms）の測定日は本文に記載がない。
- 未確定: Server の未リリース状態が現在も続くか。本文の baseline 記述はこの前提に依る。
- 未確定: collaboration 関連ライブラリの依存削除（package.json / lockfile）の承認状況。

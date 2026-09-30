# Server Workspace への取り込みと再接続

2026-09-29。利用者の「既存の会議へ再接続」および新規・既存の Server Workspace への取り込みを共通化する指示に基づき採択。

## 背景と置換範囲

[Organization ownership](../shared/organization-vaults.md) の Local 取り込みは、Server に同じ ID があると全体を拒否していた。途中まで同期した後に Local Account へ戻したコピーでは、この検査により同じ会議へ戻れない。
通常の取り込みの衝突拒否は維持し、明示的に選択する「既存の会議へ再接続する」を追加する。同じ Workspace ID の Server Workspace も取り込み先として選べる。同じ ID の Local / Server 名が違うときは対応を画面に示す。再接続前に同一 ID の別行を自動登録せず、再接続後に Server 名を採用する。

## 決定

- 新しい Server Workspace に取り込む場合も、Local Workspace 自体の ID / 所属を変更しない。Local と独立した UUID で Server Workspace を作成し、取得・登録した移行先へ既存の取り込み処理を適用する。新規・既存で異なるのは移行先を作成するか選択するかだけとする。Server の作成 API は既存の client-proposed UUID を使う。
- 作成前に、元 Workspace・接続・Organization・指定名に対応する移行先 ID と正確な transaction 本文を SQLite に保存する。再試行では discovery で同じ移行先を探し、未確認なら同じ作成要求を再送する。応答消失や再起動で別 Workspace を増やさない。指定名や Organization を変更した場合は別の作成要求として扱う。
- 元 Workspace の設定・ローカル書き出し先・instructions は移行元に残す。移行先の設定を採用し、バックアップ後に内容と送信待ちを原子的に移す。空の移行先作成後に失敗してもローカル内容は維持し、次回は作成済み移行先を再利用する。
- 作成再試行状態は当初 `v49_workspaceImportDestinations` で導入し、2026-09-30のユーザー承認により未リリース分を `v52_documentsAndSync` に統合する。配布済み migration は変更しない。ローカル取り込み確定時に対応する作成状態を削除し、その後は既存の固定 import / outbox で完了を追跡する。再試行状態は端末固有のため portable backup へ含めない。
- 旧実装で Local / Server の ID が一致する場合だけ、以下の明示的な再接続で既存 identity を引き継ぐ。新規作成ではこの状態を作らない。

- 画面で Server 側の既存データを採用することを説明し、既定では無効な再接続を利用者が選ぶ。会議 ID の変更、同名による推測、自動上書きは行わない。
- ローカル版を既存の portable backup に保存してから、検証済み Server snapshot を一時 SQLite に段階保存する。本文全体をメモリへ蓄積しない。
- 接続・権限・録音・送信待ち・transfer fence を再検証し、所属変更、Server の確定 revision と cursor、未同期レコードの送信待ちを1つのローカル transaction で確定する。失敗時は元の Local コピーを維持する。
- 既存の会議・Project・本文・画像・添付は Server の版を採用し、本文は通常の hydration で取得する。既存会議に属する未送信の本文・添付も、会議本体とは別に送信する。Server が採用した録音 source は変更せず、準備済みの未送信 source だけを追加する。ローカルの録音ファイル・準備済み音声は保持する。
- 別のローカル Workspace が所有する ID や異なる会議に属する添付・録音へ再接続しない。対象外 Workspace のデータを書き換えない。
- 非公開 Notes / Documents は従来どおり非公開コピーに保全する。再接続は公開の承認を兼ねない。
- 再接続後の通常編集は既存の revision に基づく競合検知を使う。snapshot 取得後の Server 変更を無条件に上書きしない。削除済みデータの ID 再利用拒否も変更しない。

Workspace 全体の削除、権限移管、sign-out 時の非公開データ保全の契約は変更しない。依存関係と Server API は追加しない。

## 2026-09-30: 再接続時の欠落をServerの状態として採用

ユーザー承認により、上記の「Serverにないレコード・本文・添付・録音sourceを送信する」決定を置き換える。
再接続ではsnapshotにないデータを未送信と推測しない。取り込み前のバックアップにローカル版を保全した後、
会議・Project・本文・File・添付・録音のローカル欠落分を取り込み対象から除外し、Server snapshotを採用する。
この処理はtransfer fence・接続・認可の再検証後、所属変更と同じtransactionで実行し、失敗時はrollbackする。
非公開Notesは端末内コピー／復元履歴に保全し、会議が存在しなくなっても保全内容を削除しない。
既存録音の不足sourceも送らず、Server版のみを共有状態として扱う。通常のportable backupは音声payloadを含まないため、Serverにない録音はローカル専用のまま保持し、親会議もServerにない場合はmetadata・ファイル参照・準備済み音声を「再接続前のローカル録音」Workspaceへ保全する。音声ファイル自体は削除しない。
同一Workspaceへの再接続と別Workspaceへの再接続に同じ規則を適用する。
通常の新規取り込み（再接続を選ばない場合）は従来どおりローカル内容を送信する。
Server API・永続削除履歴・依存関係は追加しない。

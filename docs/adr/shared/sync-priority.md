# Desktop の優先同期と文書ロック

2026-09-30。利用者が承認した「Desktop 同期の優先制御・Notes の低遅延化・Server ロック分割」を採択する。採択と実装・検証の完了は区別する。

## 置換範囲

`sync.md` の Workspace FIFO、blocked 以降の一括停止、ACK による通常受信全体の無効化と、`documents.md` の Desktop の送信間隔を変更しない決定を置き換える。Web の100ms固定窓、正本・権限・冪等性・録音保護は維持する。

## 決定

- 操作を通常と背景に分類し、通常4件に背景1件の実行機会を与える。Workspace間は巡回する。最新優先は古い変更の破棄や同一entityの逆順送信を意味しない。
- 作成・削除・所属変更に必要な依存と同一entityの順序を永続化する。旧・新の親とProjectの2階層を保護する。依存不明・backfill前はWorkspace barrierとし、必要な親操作の優先度を引き上げる。
- 競合解決はblockedと依存する後続だけに限定する。lease中・応答不明は元IDの結果を確定するまで破棄・再登録しない。
- 受信を送信と独立させる。通常受信では接続・認可・reset・移管の世代とentityのrevision/pendingを再検証し、無関係なACKで全体を中断しない。snapshotと本文hydrationの厳しい保護は維持する。
- 音声アーカイブは別タスクとし、必要な親ACKで開始可能にする。大容量転送は合計4枠、背景最大3枠。Notesは別枠。本文取得の既存2枠・背景最大1枠は維持する。
- 初期構築はentityごとに再開可能にし、構築済みの編集は後続として、未構築の編集は最新初期状態として記録する。Local取り込み・復元・初期同期に共通適用する。
- DBごとのDocumentSyncServiceを共有する。Desktopはローカルcommit後200ms固定窓で送信し、表示文書は専用SSEを共有する。Webは100ms。切断補完は2秒、flushは即時、親会議ACKを先に待つ。
- Serverは認可共有/排他、Workspace lifecycle共有/排他、domain更新排他、Document共有/排他に分離する。この順序と複数IDの昇順を守り、途中昇格しない。認可変更と削除/移管は排他、通常domainとDocumentsは並行可能にする。RLS・暗号化は維持する。
- 要約待機は対象会議の入力と依存へ限定し、Notes同期失敗を省略で回避しない。

## 検証と境界

使い捨てDBで約8,000件の背景操作、編集・録音・Notes・要約・競合解決・応答消失・再起動を検証する。初期構築中の編集を含める。PostgreSQLはロック取得を観測して認可変更・親削除・移管との競合を検証する。SQLiteは既存のtransaction直列化を維持する。

計測はDB占有/ローカル保存/送信待ち、Serverプール/ロック待ち/処理、描画を分ける。外部telemetryや内容・識別子の診断出力は追加しない。QAデータ消去・deploy・merge・release変更は対象外。Serverに存在しない再接続データの扱いは別の未決事項である。

## 実装上の境界

- 未リリースの `v50_syncPriority` は、2026-09-30の承認により `v52_documentsAndSync` に統合する。配布済み v47 録音復旧までの登録・処理は変更しない。依存索引、確定済みの親、構築済みentity、選択回数はSQLiteに保存する。既存キューは背景扱いで32 transactionずつ索引を補完する。
- 旧親はSQLiteの`BEFORE UPDATE/DELETE` triggerで記録し、recorderが同じtransaction内で消費する。行を変更済みの呼び出し元でも旧親を推測しない。未知の旧関係はbarrierを維持する。
- 初期構築の開始時には識別情報だけを登録する。本文の構築と原本の準備はentityごとに進め、全画像の準備完了を会議metadata送信の条件にしない。既に構築した要求IDは再起動や後続編集で置換しない。
- 画像、文字起こしのchunk、録音の送信は共有する4枠・背景最大3枠を利用する。domain commitの一つのtransactionは分割しない。通常の録音停止は同期を待たない。
- キャンセルだけではServerでの未確定を証明できない。leaseを解放しても試行履歴を保持し、再claim時に元IDをresolveする。Serverがunknownを返した場合だけ未送信として扱える。
- snapshot復旧と移管の全体整合性検査は維持する。会議単位の要約準備では通常差分を対象会議の依存・lifecycle世代で検査し、無関係なACKや保留entityによって待機を延ばさない。
- PostgreSQLの通常domain処理とDocumentsは認可・Workspace lifecycleを共有取得する。親や可視性が変わる操作はlifecycle排他とする。旧Serverが使う全体認可キーとWorkspaceキーを維持するため、旧インスタンスと混在している間は旧ロックによる待機が残る。

## 計測方法

外部telemetryは追加しない。DesktopはInstrumentsのPoints of Interestに、`com.dahlia` / `SyncPriority`の固定名intervalを出す。`DocumentLocalCommit`とその中の`DocumentDatabaseWrite`で保存全体とDB占有を分け、差分をDB待ちの目安とする。`DocumentSendWindow`は200ms集約待ち、`DocumentExchange`は文書同期の呼び出し全体、`DocumentApplyToWebView`は受信状態のJavaScript適用までを測る。最後のintervalは画面のpixel表示完了を意味しない。内容・ドメインID・パス・認証情報をsignpostへ渡さない。

Server内部の`captureSyncTimings()`は明示的なローカル計測だけに使う。固定名フェーズと最大128件の時間だけをメモリに保持し、`stop()`で解除する。公開HTTP APIや環境変数、外部送信は追加しない。`connectionAndBegin`にはプール取得とBEGINの両方が含まれ、純粋なプール待ちではない。`transaction`はDB callback内の処理全体で、個別の認可・lifecycle・domain・document・notesのロック待ちは別intervalとする。ロック待ちを処理時間へ二重加算しない。

再現用の使い捨てDBテスト:

- `SyncPriorityTests`: 8,000背景要求、通常4対背景1、親の優先、旧・新親、移行索引、再起動後の構築継続、会議単位の要約確認。
- `SyncTransferTests` / `SyncTransferSlotsTests`: 転送中のmetadata送信、4枠と背景上限、キャンセルと再送。
- `DocumentPersistenceTests`: 共有サービス、200ms固定窓、flushの即時実行、未送信差分と保全。
- `sync-locks-postgres.test.ts`: domainロック保持中の同／別WorkspaceのDocuments、認可剥奪、親削除、移管。ロック待ちは`pg_stat_activity`で観測する。通常時とdomainロック保持中に同じ文書交換を30回実行し、固定フェーズのp50/p95を出す。

これらのqueue/storeテストの計測値をDesktop↔WebやDesktop↔Desktopの通信・描画込みの反映時間として扱わない。実画面比較は別途、通常時と8,000件移行中の同じ入力で、端末の保存開始から相手の描画までのp50/p95を採取する。ユーザーのQA DBをその測定のために初期化しない。

2026-09-30のローカル計測では、8,000背景要求に対する通常要求の選択位置は、旧FIFO queryの8,001番目から1番目になった。同fixtureで計測した6回のclaimは9.70〜10.46msで、4通常要求の後に背景要求を選択した。これは送信完了までの時間ではない。

使い捨てPostgreSQLの短い文書に同じ差分を30回再送したstore計測は、通常時のtransaction内処理p50/p95が4.42/4.71ms、同Workspaceのdomainロック保持中は4.65/5.00msだった。domain保持中の接続取得＋BEGINは0.08/0.09ms、認可ロック0.07/0.08ms、lifecycleロック0.08/0.10ms、文書ロック0.10/0.13msだった。ローカルの冪等再送fixtureであり、新規編集の書き込み性能、QAのネットワーク、実画面の遅延の保証値ではない。

## 実施した検証（2026-09-30）

- `swift test --build-system native --experimental-maximum-parallelization-width 4`: 310 suites、2,425 tests成功。`swift build --build-system native`、`CI=true ./scripts/lint.sh`も成功。SwiftPMの終了コードだけでなくテスト集計を確認した。
- 使い捨てPostgreSQLの`TEST_DATABASE_URL`と`VITEST_MAX_WORKERS=4`を設定した`pnpm check`: 1,141成功、追加環境を必要とする11件skip。package検査とWorkers dry-runも成功。
- 別の使い捨てDBを`TEST_AUTH_DATABASE_URL`、`TEST_ENCRYPTION_DATABASE_URL`、`TEST_ORGANIZATION_DATABASE_URL`に設定し、`domain-organization.test.ts`、`workspace-encryption-postgres.test.ts`、`organization-workspaces.test.ts`を追加実行: 51成功、skipなし。全体検証と重複するテストを含むため件数は合算しない。
- `git diff --check`成功。QAデータへの変更、アプリのデプロイは行っていない。

実画面のDesktop↔Web／Desktop↔Desktop、実際の大量取り込み中の録音・描画については未測定。次の手動検証では専用アカウントとデータを用い、通常時と8,000件取り込み中に同じ編集・要約開始を行い、上記signpostと相手側の描画時刻からp50/p95を比較する。自動テストの成功を、この実画面比較の完了とは扱わない。

### 競合採用後の対象単位の再取得

既存の pull cursor があり Workspace 自体を含まない競合・validation を破棄する場合、対象 entity を永続的な再取得リストへ記録する。cursor と無関係な entity の revision は保持する。通常差分で対象が届けば同じ revision でも採用し、届かなければ snapshot から対象だけを再取得する。この処理は Workspace 全体の snapshot 復旧とは分離し、無関係な blocked transaction を待たない。取得中の mutation generation 変更、新しい対象編集、録音・移管・接続変更は既存の受信ガードで再検査する。再取得リストの消去は本文・metadata の適用と同じ DB transaction で行う。Workspace 全体の reset・初期同期・cursor 失効の厳しい復旧条件は維持する。

再取得リストは統合 migration `v52_documentsAndSync` で作成する（統合前の識別子は `v51_scopedSyncReconciliation`）。ローカルで削除した親をServer版へ戻す場合は、canonicalな子と参照ファイルも復元する。親の通常差分が先に到着しても、子の列挙を永続化するまでは再取得リストを残す。接続解除・Workspace移動・キューの全破棄では対応するリストも破棄する。

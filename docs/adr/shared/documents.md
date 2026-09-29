# 会議 Notes の共同編集 Documents 化

採択: 2026-09-29。ユーザーが承認した実装計画に基づく。採択は実装・検証完了を意味しない。

## 正本と公開

会議 Notes を Tiptap / Yjs の文書へ置き換える。Server Workspace の共有文書は Server canonical、Desktop SQLite はオフライン作業コピー、Local Account は独立した正本とする。会議 Notes の文書 UUID は会議 UUID と同じ値を使い、公開 ID は `doc_` とする。`documents.meeting_id` は一意。Yjs checkpoint と更新ログが本文の正本であり、本文テキストとブロック一覧は派生物。別の `document_blocks` / `meeting_documents` 正本は作らない。

既存 Notes は自動公開しない。Local Account の既存本文は文字列・改行・日時を保って変換する。Server Workspace の旧 Notes は端末内に残し、Workspace 単位で対象と公開先を確認してから空の文書へ一度だけ取り込む。既存の共有本文との衝突では非公開コピーを保持し、人が判断する。旧 `notes` は今回削除しない。新しい共有 Notes と復元記録は Workspace の閲覧権限を継承する。未公開本文を共有要約に混ぜない。

## 同期と復元

文書の Yjs state／単一更新は8 MiBまでとする。初回更新に正本の全状態が含まれる場合も送信できるよう、専用 API の JSON request は24 MiB、Desktop の response 受信は32 MiBまでとし、既存 domain transaction の8 MiB上限は変更しない。復元履歴は本文を読み出す前にページ量を制限し、通常6 MiB以内で返す。単一の大きな記録は分割せず1件で返し、次ページへ進める。

本文の編集には CRDT 専用 API と文書ごとの独立した送信待ちを使う。既存の `/api/v1/transactions` によるドメイン更新契約の例外であり、文書障害で録音・文字起こし・要約の同期を止めない。送信待ちでも受信をマージする。通常送信は最大2秒間隔で集約し、再送は Yjs の冪等性を使う。編集ごとの永久 transaction receipt は追加しない。SSE は revision / cursor のみを通知し、再接続時は HTTP による差分交換で復旧する。

同じ段落への同時入力を許可し、排他ロックを設けない。段落の削除前と、受信マージで自身の編集が消える前の内容を復元用に保全し、通知する。ACK だけで未確認の復元用状態を破棄しない。復元は新しいブロックの挿入とし、文書全体を古い状態で置換しない。復元記録は自動期限削除せず、親の物理削除に従う。安定したブロック ID、分割・貼り付け時の新 ID、正本 worker による重複修復を共通コアで扱う。

文書の作成・削除・復元・移管・reset は会議と Workspace の認可・ライフサイクルに従い、遅延した編集で削除済みの親を復活させない。viewer は read-only。権限失効時の未送信編集を黙って破棄しない。presence は共有 DB に保存する5秒 heartbeat / 15秒 TTL のユーザー一覧で、本文や同期キューとは分離する。

会議を削除すると文書の送信世代を変更し、削除中の本文取得・更新と旧世代の送信を拒否する。利用者が会議を明示的に復元した後は、認可された最新 checkpoint を取得してから、新世代で未送信差分をマージする。Desktop と Web のエディタ・保存先は同じ Yjs の依存関係を保持し、保存先だけを空にしない。Workspace／Account をまたぐ未公開コピーの保全は、引き続き別の公開確認に従う。

## Runtime と保存

文書操作・差分集約・同期状態・復元判定は DOM / Node に依存しない TypeScript コアとする。保存、通信、時刻と乱数は host adapter で提供する。Web と Desktop WKWebView は共通 Tiptap エディタを使う。Desktop の JavaScriptCore は専用スレッドに隔離し、エディタ非表示でも同期できる。将来の Electron はこのコアとエディタを再利用し、renderer 外の SQLite adapter に接続する。

Desktop は差分と送信待ちを短い SQLite transaction で保存してから保存済みと通知する。本文生成・マージ・checkpoint 作成は MainActor と DB write transaction の外で行う。通常時250ms以内のローカル commit を目標とするが、強制終了前の未確認入力の保全時間は保証しない。録音停止に文書待機を追加しない。通常終了・画面切替はローカル commit だけを待つ。今回の Web はメモリのみで、閉じた後の未送信入力は復元保証の対象外。

本文・差分・復元記録・要約 snapshot は既存の Server 暗号化 store と RLS の対象。Notes の FTS / 検索 / Hindsight への直接取り込みは追加しない。再取得可能な共有文書キャッシュは既存128 MiB LRUへ含め、未送信・非公開・復元用・Local Account のデータは解放しない。バックアップ、移管、Server→Local、サインアウトで同じ保存境界を維持する。

## 要約

ジョブ受理時の共有 Notes の ID・revision・本文（存在しない状態も含む）を内部専用 `notesSnapshot` として暗号化保存する。現在の Notes を入力 fingerprint の再検査へ含めず、既存入力の変更検知は維持する。Notes を含めて2,000,000 UTF-16 code unitsの上限を適用し、XML escape した untrusted data として渡す。状態 API で snapshot 本文を返さない。

Desktop / Web の開始と明示的な `/retry` は編集を送り切ってから実行する。Server だけの開始では受理時の Server 状態を使う。同じジョブの自動再試行は同じ snapshot、新しい `/retry` ジョブは最新 snapshot を使う。既存ジョブには後付けしない。Server Workspace のローカル要約にも共有 Notes だけを含める。

## 配布と migration

Desktop v0.22.0 は v45、v0.23.0〜v0.24.1 は v46 まで配布済み。v1〜v46 の登録名・順序・処理と呼び出し先を保持し、新しい forward migration だけを追加する。旧文書の未配布という記述は過去の統合時点の記録である。Server は未リリースのため Drizzle baseline / snapshot / manifest を整合させて統合できるが、既存 DB の自動消去・履歴書換えはしない。

Server / Web / Desktop を `sync.version = 7` へ一括更新し、`documents: { version: 1 }` を追加する。Node / Workers 共通で Documents を提供し、要約の runtime 対応範囲は維持する。TypeScript は当面 `apps/server` が所有し、既存 Vite / tsup で Desktop 同梱資材を生成する。root workspace は追加しない。

依存追加は `yjs`、`@tiptap/core`、`@tiptap/react`、`@tiptap/pm`、`@tiptap/starter-kit`、`@tiptap/extension-collaboration`、`@tiptap/extension-unique-id`、`@tiptap/y-tiptap`。バージョンを固定し、同梱ライセンスと生成物の再現性を検査する。

## 既存決定との関係と範囲

[sync](sync.md) の note 除外は旧端末内 Notes には維持し、明示公開した Documents には本 ADR の専用契約を適用する。[Server 要約](../server/summary-generation.md) のローカルメモ非送信は維持し、公開済み Documents の snapshot を入力へ追加する。[依存管理](../monorepo/dependencies.md) はアプリ単位を維持して生成資材を共有する。MCP / Agent の文書ツール、AI 書き込み、汎用文書一覧、Summary エディタ統合、カーソル共有、IndexedDB / PWA、Electron 本体は次段階。リリース・マージ・デプロイは今回の実装範囲外。

## 検証

Yjs の逆順・重複・オフライン再接続・削除競合・Undo / Redo / IME、ローカル commit と再起動、バックアップと移管、認可 / RLS / 暗号化、全要約開始経路と再試行を検証する。Desktop は公開タグ相当の v41 / v45 / v46 からの更新とバックアップ復元を確認する。Node / Workers / JavaScriptCore の共通 fixture、Desktop / Web の実画面、Swift build / 全テスト / lint、Server `pnpm check` を実行し、テスト件数を確認する。

# 録音ストレージと保存期間

対象: Desktop。採択: 2026-07-15、保存期間改訂: 2026-08-26。以下は設計上の保証で、全項目の実装・検証完了を意味しない。現在の適合状況は [Architecture](../../../ARCHITECTURE.md#conformance-status) を参照する。

## 決定と理由

2026-07-15、復旧処理が録音中の partial CAF を final へ移した後、停止処理が final を削除して存在しない partial の移動に失敗し、唯一の音声を失った。PR #95 (`deb269b`) は既存 final の無条件削除を止めたが、単一の長時間 CAF、所有権不明の復旧、DB とファイルの非原子的更新という原因が残った。

短い CAF segment、不変な完成ファイル、process lock / session lease、永続状態機械を `RecordingAudioStore` の mutation 境界へ集約する。capture runtime は `RecordingSessionController` が所有し、callback に sync、hash、DB write を持ち込まない。

## 所有境界

- interactive instance は1つ。Launch Services の二重起動禁止に加え、DB の read-write open / recovery / recording より前に process-wide non-blocking `flock` を取得する。競合側は無変更で終了する。
- session の `.lease` も排他的に保持し、取得できない session は復旧・削除しない。PID、時刻、`endedAt` を liveness の根拠にせず、期限による lock 奪取もしない。
- 新規録音だけを segment 方式へ移す。既存 Meeting、session、transcript と旧録音 metadata を保持し、旧 managed single-CAF / Vault CAF は新しい復旧・再文字起こし・retention の対象へ backfill しない。親を明示削除する既存 cleanup は維持する。
- Data Protection、FileVault UI、backup exclusion、App Sandbox、app-level encryption は別判断。`.completeUnlessOpen` を既定採用しない。画面ロック中の transcription と削除を止める可能性があるためである。

## Segment と保全済み範囲

音源ごとに60秒を rotation 目標とし、frame 境界で次 writer を準備してから旧 writer を callback 外で確定する。finalizer は音源内で直列化する。60秒は RPO や hard deadline ではない。

1. 通常は active 1本 + finalizing 1本。遅延時は finalizing backlog を最大2本まで許容する。
2. backlog 上限では rotation を延期して active を伸長し、解消後に再開する。
3. append failure、disk 安全下限、測定で定めた有限の時間 / byte budget 到達時だけ error stop する。無制限のまま rollout しない。

未確定範囲は通常最大2本、縮退時最大3本。件数、pending bytes、最古の確定開始時刻を観測し、縮退と保全済み区間を UI で区別する。

開始 transaction で参加済み `requiredSources` と各 source の progress を登録し、session 中に暗黙除外しない。`durableThroughOffsetSeconds` は先頭から連続した ready segment の終端だけを示す。全 source の最小値を `fullyDurableThroughOffsetSeconds` として導出し、重複保存しない。sample rate の異なる音源を共通 frame count で比較しない。開始できなかった音源は別途 capture failure として表示する。

segment index と一意な generation / path を先に登録し、排他的 create を使う。既存 partial を消さず、ready CAF は上書きしない。range は file-local frame と session offset を保持し、segment 境界で分割する。

## 確定手順

1. 旧 writer を seal し、`sealedFrameCount` を確定する。
2. DB で `recording → finalizing`、予定 path と開始時刻を commit する。失敗時は publish しない。
3. writer queue を drain して CAF を close し、`F_FULLFSYNC` する。
4. readable format、sample rate、channel count、sealed frames を検証し、byte count と SHA-256 を計算する。
5. 検証済み metadata と digest 一式を `finalizing` のまま DB へ commit する。この barrier 前に rename しない。
6. 同じ directory の一意な final path へ rename する。既存 final の事前削除・置換はしない。
7. DB で `ready` と final metadata を commit し、同じ transaction で連続 ready 範囲の source cursor を進める。

DB と file は同一 atomic commit にできないため、中間状態から roll forward する。publish 後の final 自身から期待 digest を後付けして自己認証しない。

## 復旧と削除

| State / observation | Action |
| --- | --- |
| recording + partial、lease 取得可能 | readable な最後の frame まで seal して finalizing へ進める |
| recording + final | 期待 integrity metadata がなければ保持して failed |
| finalizing + partial | 保存済み sealed frames と integrity metadata を確認し確定を再開 |
| finalizing + final | publish 前の format / frame / byte / digest 一式と一致する場合だけ ready |
| ready + 一致する final | 無変更 |
| ready + missing / mismatch | failed。自動再作成・上書き・削除しない |
| purgePending + expected file | root / generation / path を再検証して unlink、不在確認後に purged |
| purgePending + 不在 | purged |
| purgePending + 曖昧な path / file | 自動 unlink せず参照と file を保持して failed |

partial と final が両方あれば期待 metadata と一致する方だけを採用し、他方を同じ処理内で消さない。選べない場合は両方保持して failed。未知 generation / orphan を age だけで削除せず、permission / volume unavailable を missing や corruption と混同しない。再試行可能な unlink 失敗では参照と purgePending を保持する。

文字起こしは検証済み ready segment だけを使い、結果一式と `batchCompletedAt` の DB commit 前に元音声を消さない。削除は DB の purgePending → unlink → 不在確認 → purged の順。Meeting / Project 削除も、file 削除前に cascade で唯一の参照を失わない。録音中、文字起こし中、曖昧な状態は削除を拒否する。

現在の retention は次節の保存期間を適用する。非公開の grace copy はユーザーの削除意図に反するため作らない。purged は live path の不在であり、backup / snapshot を含む secure erase を意味しない。

## 保存期間

バッチ録音は既定3日、無期限 / 1 / 3 / 7 / 14日から選ぶ。現在設定を endedAt と batchCompletedAt の遅い方から計算し、過去 session にも適用する。個別 TTL / 保持例外は保存しない。文字起こし成功済み・再処理中でない・failed segment のない session だけを既存 purge state machine で自動削除する。

旧「保持」選択者は無期限、その他は3日へ移し、即時削除は提供しない。利用者が選ぶまで既定値を UserDefaults に書かない。期間短縮は期限超過した既存録音の即時削除を確認し、purge 開始後に設定を戻しても復元しない。リアルタイム文字起こしは音声を保存しないため対象外。

誤言語での文字起こし成功直後に音声を失う問題から、session 固定の削除 / 保持方針を変更した。旧 retention column は migration 履歴だけに残し runtime は参照しない。immutable segment、失敗時の保持、purge intent、active / ambiguous な音声の削除拒否は維持する。

## 制約と検証

管理 root は0700、CAF / lease / metadata は0600。破壊操作の直前に canonical root を検証し、絶対 path、`..`、symlink で root 外を操作しない。内容、full path、digest、音声由来 metadata を通常 log / Sentry に送らない。POSIX permission は同一ユーザーの malware や root への防御ではない。SSD / volume 故障、紛失、未確定 segment の無損失、全物理コピーの消去は保証しない。

ファイル数、DB 行、I/O と reconciliation が増える代わりに損失範囲を限定する。単一 CAF の rename 強化だけ、同一 volume への二重書き込み、SQLite BLOB、user folder への直接録音、Launch Services / NSFileCoordinator だけの排他は、所有権・障害範囲・耐久性の問題を解決しないため却下した。

実 process / file system で lock 競合、各 commit / sync / rename の前後の crash、DB × partial/final の状態 matrix、同長 digest mismatch、frame 連続性、backlog 縮退、複数音源 cursor、unlink 再試行、root guard、既存データ保持を検証する。実装適合状況は architecture とテストを確認し、本 ADR の Accepted を rollout 完了の証拠にしない。

# 録音音声の保存と Server 保管

- 採択: 2026-09-07。Server の音声保管の例外をユーザーが承認した。
- Local Workspace の保存方式は下記「Local Workspace の保存」に従う（2026-09-16 の決定）。

## 決定

導入後に開始するバッチ録音だけを対象とする。マイクとシステム音声は混ぜない。録音と文字起こしは端末で完結し、停止や確定文字起こしの永続化は圧縮・ネットワークを待たない。既存録音とリアルタイム方式は変更しない。

PRODUCT.md の「クラウドでの音声保管」を除外する判断の限定的な例外である。クラウドでの音声認識・音声処理、動画保管、既存録音の一括変換は行わない。

## Local Workspace の保存

検証済みの CAF を音源ごとに、設定された保持期間だけ保存する。M4A への結合保存は行わず、CAF の早期削除もしない。保持期間は Local Workspace の CAF と互換 M4A にだけ適用する。

保持期間内の再文字起こしは CAF を入力とし、区間ごとに言語を自動判定して Apple Speech で処理する。既存 Local M4A と準備途中の archive は互換入力として読み取り、再変換や期限前の削除は行わない。期限到達時に CAF と同じ既存 purge 処理で削除する。

## Server Workspace の保管

Server Workspace のバッチ録音は、session・音源ごとに検証済みの CAF を AAC-LC・16 kHz・モノラル・制約付き VBR 48 kbps・最高エンコーダ品質の音源別 M4A に変換してアップロードする。逐次処理でメモリを抑え、収録の空白・区間・言語を manifest に保存する。完成後は全体を復号し、サンプル数と SHA-256 を検証する。途中失敗時は元の CAF を維持し、作成済み M4A を再送に使う。

確定音声は Workspace と同じ閲覧権限で期限なく保管し、owner が別端末でも再文字起こしできる。保持期間は Server の確定 M4A には適用しない。Server Workspace の初回の文字起こしの処理場所、workflow、言語設定は維持する。

元 CAF は、全音源の確定保存・復号検証・文字起こし成功・Server の再取得照合を満たした後に既存 purge state machine で解放する。CAF 削除の実行条件に認識品質の評価は含めない。既存の保存済みアーカイブにも、再検証後に同じ条件で適用する。

CAF の削除失敗は保存済み M4A の利用可能状態を変更しない。削除開始済みなら、通信・保存検証を繰り返さず既存の削除処理を再試行する。再文字起こしは削除済み・削除保留の CAF を入力にせず、保存済みアーカイブを使う。明示的な再文字起こしは、アップロード済みの完全な M4A 集合だけを入力とする。

## 削除と保護

保存準備中・失敗中の元 CAF と、変換・アップロード・再文字起こしが未完了・失敗・再試行中の音声は、既存の状態機械で保護し、自動保持期限から外す。

会議または Workspace の明示削除は、Local CAF、互換 M4A、Server の staging / 確定 M4A と処理ジョブを既存の cascade と削除キューで除去する。遅延した結果を復活させない。

## API と同期

[OpenAPI 契約](../server/openapi.md) の `PUT /api/v1/meetings/{meetingId}/recording-uploads/{sessionId}/audio/{source}`（`sessionId` は UUIDv7、`source` は `mic | system`）に `Content-Type: audio/mp4`、`Content-Length` と raw bytes を送る。1音源1ファイル、上限1 GiB。サーバーがサイズ・SHA-256を計算し、同一再送は200、新規保存は201、異なる内容は409を返す。

sessionId は内部識別子として保持する。公開録音番号は meeting 内でアップロード採番順の正整数とし、同じ session の両音源が同じ番号を使う。番号は再利用せず、録音開始・終了時刻を別に保持する。保存キーは `meetings/{meetingId}/recordings/audio_mic_01.m4a` などの平坦なパスとする。

アップロード後は owner だけが読める staging とし、クライアントの照合後に `recording:upsert` transaction で checksum・音源・manifest を確定する。sync snapshot / delta は内部 session と公開番号の対応を配信する。公開一覧 `GET /api/v1/meetings/{meetingId}/recordings` は確定音源だけを番号別に返し、sessionId を公開しない。`GET /api/v1/meetings/{meetingId}/recordings/{recordingId}/audio/{source}` は公開録音番号を `recordingId` に使い、Range に対応する。同じパスの HEAD は Range を無視して全体のヘッダーを返し、本文は送らない。物理キーや認証情報は公開しない。Files API の既存64 MiB制限は維持する。

Server は新しい sync entity を旧 Desktop が誤読しないよう、`recordingArchive: { version: 1 }` を広告する。音声の送信は recordingArchive.version 1 の Server に限る。更新順序は Server / Web、Desktop とする。

未確定 staging は24時間で失効する。Node の1分間隔の保守処理と Worker の毎分 Cron が全 Workspace の運用 metadata をページングし、owner identity の transaction 内で期限切れ音源を削除キューへ入れる。Workspace への後続リクエストは不要。削除キュー・キー排他・世代照合で再送・明示削除と競合しないようにする。

CAF の削除開始は `purgeRequestedAt` で判定する。削除時の整合性異常で行が `failed` になっても、その CAF を再文字起こしの入力に戻さない。

## 認識品質の評価基準

正解文付き日本語・英語の自然音声に、固有名詞、数字、小声、雑音、重なり、結合境界を含める。同じ条件の Apple Speech とローカル Whisper で元 PCM／復号 PCM を認識する。日本語 CER・英語 WER は、エンジンと言語別の集計悪化0.5ポイント以内、個別悪化2ポイント以内を条件とする。サイズ、経過時間、ピークメモリも記録する。不合格の場合はサンプルレート変更を含む別設定を再検討する。

認識結果を同じ正解文と対にして、`python3 apps/macos/scripts/check-recording-quality.py results.json` で採点する。入力は `{id, language: "ja"|"en", engine: "apple"|"whisper", reference, original, decoded}` の配列。このツールは音声送信や認識を行わず、両エンジン・両言語の結果が揃わなければ失敗する。`--self-test` は採点処理だけの検証であり、品質評価の代わりではない。

## 測定

- 2026-09-07 の macOS 実機検証で、64/96 kbps は macOS 標準 AAC の 16 kHz モノラルで受け付けられないことを確認した。16 kHz を維持する 48 kbps を採用し、品質基準は緩めない。
- 単体テストの合成音声は復号・時刻の検証にだけ使い、認識精度の根拠にはしない。

## 却下した案

- 64 kbps / 96 kbps の AAC: macOS 標準 AAC の 16 kHz モノラルで受け付けられないことを実機で確認したため。
- Local Workspace のバッチ録音を M4A に結合して保存し、CAF を早期に削除する方式: 元の記録に理由の記載はない。現在は CAF を保持期間だけ保存する。

## 未適合・未検証

- 未確定: Server 再文字起こしの入力規則（完全な M4A 集合だけを入力とする）が、[アカウント別 Desktop 推論](account-scoped-desktop-inference.md) の置換後も有効か。
- 未検証: 正解音声による認識品質評価（Apple Speech と Whisper の比較）は未実施。CAF 削除の実行条件からは外している。
- 未検証: GUI での実機操作と、配置先での長時間アップロードは未確認。
- 未検証: PostgreSQL 系のサーバーテスト（2026-09-07 の検証時に接続先未設定で未実行）。使い捨ての PostgreSQL を `TEST_DATABASE_URL` / `TEST_MIGRATION_DATABASE_URL` に設定して `apps/server` で `pnpm check` を再実行する必要がある。

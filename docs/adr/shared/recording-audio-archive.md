# 録音音声の結合保存と Server 保管

- 日付: 2026-09-07
- 状態: 採用（圧縮音声だけに置き換える品質ゲートは未通過）
- 承認: Server の音声保管の例外、および新規 Local Account バッチ録音への結合音声保存をユーザーが承認。

## 決定

導入後に開始するバッチ録音だけを対象に、検証済みの CAF を session・音源ごとに結合する。
マイクとシステム音声は混ぜない。録音と文字起こしは引き続き端末で完結し、停止や確定文字起こしの永続化は
圧縮・ネットワークを待たない。既存録音とリアルタイム方式は変更しない。

macOS の AAC-LC、16 kHz、モノラル、制約付き VBR 48 kbps、最高エンコーダ品質を用いる。
逐次処理でメモリを抑え、収録の空白・区間・言語を manifest に保存する。完成後は全体を復号し、
サンプル数と SHA-256 を検証する。途中失敗時は元の CAF を維持し、作成済み M4A を再送に使う。

Local Account はローカル M4A を再文字起こしに利用し、既存の保存期間設定を維持する。
Server Account は Vault と同じ閲覧権限で確定音声を期限なく保管し、owner が別端末でも再文字起こしできる。
元 CAF は、全音源の確定保存・再取得照合・文字起こし成功・下記品質ゲートを満たした後に既存 purge state machine で解放する。
保存準備中・失敗中の元 CAF は自動保持期限から保護する。明示的な会議／Vault 削除はこれらの保存物も削除する。

これは PRODUCT.md の「クラウドでの音声保管」を除外する判断の限定的な更新である。
クラウドでの音声認識・音声処理、動画保管、既存録音の一括変換は追加しない。

## API と同期

`POST /api/v1/meetings/{meetingId}/recordings?sessionId={uuidv7}&source=mic|system` に
`Content-Type: audio/mp4`、`Content-Length` と raw bytes を送る。1音源1ファイル、上限1 GiB。
サーバーがサイズ・SHA-256を計算し、同一再送は200、新規保存は201、異なる内容は409。

sessionId は内部識別子として維持する。公開録音番号は meeting 内でアップロード採番順の正整数とし、
同じ session の両音源が同じ番号を使う。番号は再利用せず、録音開始・終了時刻を別に保持する。
保存キーは `meetings/{meetingId}/recordings/audio_mic_01.m4a` などの平坦なパスとする。

POST 後は owner だけが読める staging とし、クライアントの照合後に `recording:upsert` transaction
で checksum・音源・manifest を確定する。sync snapshot/delta は内部 session と公開番号の対応を配信する。
公開一覧 `GET /api/v1/meetings/{meetingId}/recordings` は確定音源だけを番号別に返し、sessionId を公開しない。
`GET/HEAD /api/v1/meetings/{meetingId}/recordings/{number}/audio/{source}` は Range に対応する。
物理キーや認証情報は公開しない。Files API の既存64 MiB制限は維持する。

新しい sync entity を旧 Desktop が誤読しないよう、Server は `syncVersion: 2` と
`recordingAudioVersion: 1` を広告する。新 Desktop は syncVersion 1/2 を読み、音声送信は
recordingAudioVersion 1 の Server に限定する。旧 Desktop は更新要求状態になるため Desktop を先に更新する。

未確定 staging は24時間で失効する。削除キュー・キー排他・世代照合で再送／明示削除と競合しないようにする。

## 品質ゲート

正解文付き日本語・英語の自然音声に、固有名詞、数字、小声、雑音、重なり、結合境界を含める。
同じ条件の Apple Speech とローカル Whisper で元 PCM／復号 PCM を認識する。
日本語 CER・英語 WER は、エンジンと言語別の集計悪化0.5ポイント以内、個別悪化2ポイント以内を条件とする。
初期案の64/96 kbpsは macOS 標準AACの16 kHzモノラルで受け付けられないことを実機検証した。16 kHzを維持する48 kbpsを候補とし、品質基準を緩めない。不合格の場合はサンプルレート変更を含む別設定を再検討する。サイズ、経過時間、ピークメモリも記録する。

現時点で正解音声による認識品質評価は未実施。`RecordingArchiveEncoder.qualityValidatedForSourceDeletion`
は false のままとし、元 CAF を自動置換しない。単体テストの合成音声は復号・時刻の検証にのみ使い、
認識精度の根拠にはしない。品質評価結果と配置先での長時間アップロード検証なしにリリース完了としない。

認識結果を同じ正解文と対にして、`python3 apps/desktop/scripts/check-recording-quality.py results.json` で採点する。
入力は `{id, language: "ja"|"en", engine: "apple"|"whisper", reference, original, decoded}` の配列。
このツールは音声送信や認識を行わず、両エンジン・両言語の結果が揃わなければ失敗する。
`--self-test` は採点処理だけの検証であり、品質評価の代わりではない。

## この変更の検証記録

2026-09-07 のローカル検証:

- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --jobs 4`: 成功。
- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --experimental-maximum-parallelization-width 4 --jobs 4`: 2,236件、302 suite 成功。
- 最後のテスト記法調整後に `swift test --filter RecordingArchiveTests --jobs 4` を同じXcode指定で再実行し、4件成功。
- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CI=true ./scripts/lint.sh`: SwiftFormat、telemetry policy、SwiftLint 成功。
- `apps/server` で `pnpm check`: 269件成功、13件スキップ。型検査・lint・ビルド・インストール済みパッケージ検証・Worker dry-run 成功。
- Serverのスキーマ生成テストはSwift全体テストとの同時実行中に5秒の制限を超えた。単独で3件成功後、通常の `pnpm check` 全体も成功した。制限値は変更していない。
- `python3 apps/desktop/scripts/check-recording-quality.py --self-test`: 6件成功。認識品質の実測ではない。

追加した検証は、短いAAC末尾、結合区間の空白・言語、重複区間の拒否、元CAF削除後の既存バッチ再文字起こし、
Local保持期限、別端末のcanonical metadata、owner境界、親削除時の送信中止、未送信文字起こしを保持するDB移行を含む。
Serverは両音源の同時POST、再送、サイズ／形式／checksum拒否、Range/HEAD、staging失効後の再送、古い世代の拒否、
会議削除、履歴を全削除済みのSQLiteでの同期番号保持を検証した。

PostgreSQL系13件は `TEST_DATABASE_URL` / `TEST_MIGRATION_DATABASE_URL` 未設定で未実行。
使い捨てPostgreSQLの接続先を設定し、`apps/server` で `pnpm check` を再実行すること。
GUIでの実機操作、Apple Speech/Whisperの正解音声比較、実配置先での長時間アップロードは別途必要。

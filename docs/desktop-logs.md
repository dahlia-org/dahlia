# Desktop ログの採取

macOS 版 Dahlia の不具合を調べるときに、アプリログを採取する手順と、ログを追加するときの規則。

## ファイルログ

Dahlia は `AppLogger` で書いた行を、OSLog と次のファイルの両方に残す。設定 > デバッグ > アプリケーションログは
このファイルから直近 2000 行を表示するため、クラッシュや再起動の前のプロセスのログも読める。

| プロファイル | 場所 |
| --- | --- |
| 配布版 | `~/Library/Application Support/Dahlia/Logs/Dahlia.log` |
| 開発版（main checkout の `run-dev.sh`） | `~/Library/Application Support/Dahlia-Development/Logs/Dahlia.log` |
| 開発版（linked worktree の `run-dev.sh`） | `<worktree>/.dahlia/Logs/Dahlia.log` |

- 1 MiB を超えると `Dahlia.1.log` … `Dahlia.9.log` へずらし、最大 10 ファイルを残す。
- 起動ごとに `Dahlia launched version=… build=… pid=… os=…` の行が入る。プロセスの境界はこの行で見分ける。
- 録音・文字起こし・要約・書き出しの開始・完了・失敗（`Dahlia.Recording.failed stage=capture` など）と、
  `ErrorReportingService` に渡されたエラーの `source`、`domain`、`code` も記録する。
- クラッシュした場合は `~/Library/Logs/DiagnosticReports/Dahlia-*.ips` も確認する。

## OSLog から採取する

ファイルにない Debug レベルの計測ログ（永続化キューや画像デコードの所要時間など）は、統合ログから採取する。
zsh には組み込みの `log` があるため、`/usr/bin/log` をフルパスで呼ぶ。

```bash
# 直近 2 時間
/usr/bin/log show --last 2h --predicate 'subsystem == "com.dahlia"' \
  --info --debug --style compact > dahlia.log

# 時刻範囲と category で絞る
/usr/bin/log show --start '2026-10-05 10:00:00' --end '2026-10-05 11:00:00' \
  --predicate 'subsystem == "com.dahlia" AND category == "MicrophoneCapture"' --style compact
```

Debug は通常メモリ上にしか残らない。再現を待って調べる場合だけ、事前に保存を有効にし、終わったら戻す。

```bash
sudo /usr/bin/log config --subsystem com.dahlia --mode level:debug,persist:debug
sudo /usr/bin/log config --subsystem com.dahlia --reset
```

## ログを追加するとき

- 診断に残す行は `AppLogger(category:)` の `info`、`notice`、`error` で書く。
- メッセージはそのままファイルと OSLog に公開値として残る。文字起こし・要約などの本文、Meeting などの識別子、
  資格情報を含めない。本文やパスを含みうるエラーは、エラー文ではなく `domain` と `code` で表す。
- 録音中にフレーム、トークン、セグメント単位で出す計測は、ファイルに残さず `Logger.debug` を直接使う。

## 共有する前に

既存の行にはデバイス名やエラー文が含まれることがある。Issue などへ添付する前に内容を確認する。

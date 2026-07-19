# ADR-0008: ストリーミングチャット Markdown を bounded UI projection として描画する

## Status

Accepted

## Date

2026-07-19

## Context

Codex チャットは自由形式 Markdown の delta を逐次受信するが、従来は生成中だけプレーンテキストを表示し、turn 完了後に Markdown
へ切り替えていた。生成中から同期的に Markdown を解析すると、応答が伸びるたびに MainActor 上で全文の block 解析とインライン装飾生成を
繰り返し、録音中の UI や操作を停滞させる可能性がある。また、更新ごとの全文を共有キャッシュへ保存すると、内容がほぼ同じ長文で固定容量を
埋め、不要なメモリ使用を招く。

[ADR-0002](0002-isolate-recording-critical-path-from-main-actor.md) は重い表示処理を MainActor から分離し、再生成可能な UI 投影を有界にする
方針を定めている。[ADR-0003](0003-use-a-shared-codex-app-server.md) は raw Markdown delta の逐次表示と `item/completed` による最終本文の
整合を要求している。本 ADR は両方を維持しながら Markdown 表示を逐次適用する方法を定める。

## Decision

- 結合済みの raw Markdown を会話内容の正本とし、解析済み block は破棄・再生成可能な UI projection とする。
- block 解析と `AttributedString` の Markdown 変換は Markdown view ごとの専用 actor で直列化し、MainActor では入力の集約、完成した projection の状態更新、レイアウトだけを行う。
- view ごとの coordinator は実行中の描画を 1 件、待機中の入力を置換可能な最新 1 件だけ保持する。古い delta の projection を FIFO で再生せず、別のメッセージやウインドウの描画も同じ actor で待たせない。
- パーサーは block と行の処理中に cancellation を確認し、不要になった長文解析を有限時間で終了できるようにする。
- ストリーミング途中の全文は共有キャッシュへ保存しない。`item/completed` と整合した完了済み Markdown だけを、件数と raw UTF-8 byte 数の両方に上限を持つキャッシュへ保存する。
- 解析中は直前の projection と未描画の raw suffix を同時に表示する。非 prefix の置換または初回 projection では raw text 全体を fallback として表示する。
- 直前の parse 結果と一致する先頭 block の `AttributedString` は再利用し、更新中の末尾 block だけを再変換する。

## Invariants

- 描画の集約、キャンセル、キャッシュ eviction は raw Markdown を変更しない。
- turn の停止または失敗時も受信済みの raw Markdown を残す。
- Markdown 描画は app-server transport、録音 runtime、文字起こし永続化を待たせない。
- チャット本文と projection を診断ログや Sentry context に含めない。

## Consequences

- 生成中から見出し、リスト、引用、コード、インライン装飾が段階的に表示され、完了時の全面的な表示切り替えがなくなる。
- delta ごとに MainActor で全文解析せず、古い解析要求とキャッシュ項目が無制限に蓄積しない。
- Markdown 記法が未完の間は記号が一時的に表示され、後続 delta で構文が完成した時点で局所的に装飾が変わる。
- 初めて表示する履歴メッセージは非同期 projection の準備まで短時間 raw text で表示される場合がある。
- Foundation の単一 `AttributedString` 変換自体は途中キャンセルできないが、view ごとの actor に隔離するため、他のメッセージの描画や MainActor を待たせない。

## Tests

- 未完の Markdown と長文を parser、projection renderer、cache のテストで確認する。
- ストリーミング断片をキャッシュせず、完了済み projection の件数と総コストが上限内に収まることを確認する。
- coordinator が中間入力を集約し、古い結果を反映せず、未描画 suffix を維持し、完了時に同一本文を再解析しないことを確認する。

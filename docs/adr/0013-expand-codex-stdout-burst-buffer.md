# ADR 0013: Codex stdout の burst buffer を拡張する

- Status: Accepted
- Date: 2026-07-28
- Amends: [ADR 0003](0003-use-a-shared-codex-app-server.md)

## Context

ADR 0003 は Codex app-server の未消費 stdout を最大 256 行に制限し、超過時には共有接続を破棄する
fail-fast 方針を採用した。複数の要約を並列に再生成すると、共有 dispatcher が処理するより先に 256 行を超える
JSONL が短時間に到着し、すべての進行中 turn が失敗することがある。

一時的な burst は吸収する必要がある。一方で、message loss や無制限なメモリ使用を許容してはならない。
また、行ごとの `removeFirst()` は、未処理配列全体を繰り返し移動する。

## Decision

- stdout の未消費行上限を 256 行から 1,024 行へ拡張する。
- 上限を超えた場合は、従来どおり protocol violation として共有接続を破棄する。
- queue の取り出しには read offset を使い、消費済みの `Data` payload は直ちに解放する。
- 空になった prefix は一定量を消費した後にまとめて圧縮する。
- この変更では要約生成の並列実行数に新しい上限を設けない。

## Consequences

- 通常の一時的な stdout burst に対する許容量は 4 倍になる。
- 未消費行数は引き続き明示的に制限され、消費済み payload も圧縮まで保持されない。
- 1,024 行を超える burst では共有接続が失敗するため、進行中の turn へ影響する可能性は残る。
- 並列実行数の制御が必要になった場合は、別の挙動変更として判断する。

## Alternatives considered

- **buffer だけを拡張して `removeFirst()` を維持する:** 取り出しごとの配列移動が残るため採用しない。
- **buffer を無制限にする:** 入力規模に応じてメモリ使用量が増え続けるため採用しない。
- **同時に要約生成数を制限する:** ユーザーに見える実行挙動を変えるため、この変更には含めない。

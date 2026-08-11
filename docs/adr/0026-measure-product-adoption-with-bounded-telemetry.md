# ADR-0026: 境界を制限した数値と内蔵 AI 利用イベントを計測する

## Status

Accepted

## Date

2026-08-10

## Context

ADR-0025 は主要 workflow の成否を匿名に観測できるようにした一方、正確な時間・件数を送らない方針を採用した。その event count から録音回数と利用者数は集計できるが、新規 meeting と再開録音を区別できず、1録音あたりの時間、AI chat、内蔵 MCP の利用状況も把握できない。

録音秒数や tool 名をそのまま送る必要はない。TelemetryDeck の `floatValue` は数値集計に使え、録音時間を丸めて上限を設ければ、内容や record ID を送らずに平均時間を把握できる。AI chat と MCP も user action または terminal tool call の低頻度境界だけで計測できる。

## Decision

- 録音 event に、最初の recording session か再開かを示す固定 `meetingScope` を追加する。
- 永続化に成功した録音時間を分単位に四捨五入し、最大360分へ制限して `Recording.completed.floatValue` に送る。failed event に時間は付けない。
- AI chat は新規 manual prompt と Live Mode 有効化だけを数える。retry、内容、live transcript segment、生成結果は送らない。
- 内蔵 Codex chat と summary が実行する MCP tool call だけを origin、粗い機能 category、read/write、成否で数える。外部 MCP client は計測しない。
- 本体と内蔵 MCP helper は同じ TelemetryDeck App ID を使い、固定 `runtime=app|mcpHelper` で分離する。本体 DAU/session は `runtime=app` で集計する。
- event count と user count は TelemetryDeck の集計を使い、custom parameter として件数や user ID を送らない。
- ADR-0025 の allowlist、内容・識別子禁止、adapter 境界、best-effort、非ブロッキング、独自 queue 禁止は維持する。

## Consequences

良い影響:

- Recording DAU、新規録音 meeting 数、録音 session 数、完了録音の平均時間を異なる意味の指標として扱える。
- AI chat と内蔵 MCP の採用状況を内容データなしに把握できる。
- 時間の丸めと上限、MCP の粗い category により詳細な行動履歴を避けられる。

トレードオフ:

- 30秒未満は0分、30秒以上90秒未満は1分となり、360分を超える録音は平均値を過小評価する。
- 同じ App ID の未 filter session 集計には内蔵 MCP helper が混ざるため、`runtime` filter が必須になる。
- helper の background 初期化前やプロセス終了直前の tool call は欠測し得る。
- 旧 version には `runtime` がないため、新しい指標の基準期間はこの変更を含む release から開始する。

## Relationship

ADR-0025 の「時間を送らない」「`floatValue` と default parameter を使用しない」という部分を置き換え、それ以外を継承する。

## References

- policy: [`docs/telemetry.md`](../telemetry.md)
- [ADR-0025](0025-adopt-allowlisted-nonblocking-telemetry.md)

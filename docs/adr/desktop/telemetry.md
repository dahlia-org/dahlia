# 匿名 telemetry

対象: Desktop・内蔵 MCP helper。採択: 2026-08-10、要約 MCP 廃止を反映。許可する event / field の正本は [Telemetry policy](../../telemetry.md)。

## 収集と実行境界

Sentry は匿名技術診断、TelemetryDeck は低頻度の機能利用を担う。SDK の custom parameter は自動匿名化されないため、自由な dictionary を公開せず、固定 enum と allowlist だけを adapter へ渡す。

`TELEMETRYDECK_APP_ID` 未設定は無効、Debug は Test Mode。opt-out UI は設けない。SDK import / call は TelemetryDeckClient だけ、cache を読む初期化は background で行い、その前の event は欠測を許容する。送信完了を機能の成功条件にせず、独自送信・retry・永続 queue は作らない。

内容、識別子、path、自由文、正確な時刻・件数を custom parameter に送らない。Sentry の明示 error capture も生の Error 説明を固定 category と許可 tag に縮める。SDK 既定 metadata と実行挙動は dependency 更新時に監査する。

## 許可した集計

- 録音の初回 / 再開を固定 meetingScope で区別し、永続化成功分だけを分単位に四捨五入・最大360分の floatValue として送る。failed に時間を付けない。
- chat は新規 manual prompt と Live Mode 有効化だけを数え、retry、transcript event、入力・生成内容を送らない。
- 内蔵 chat の MCP terminal call を粗い category、read/write、成否で数える。外部 client と廃止した summary MCP origin は計測しない。
- 同じ App ID の app / mcpHelper を固定 runtime で分け、本体 DAU / session は app に絞る。件数・user count はサービスの集計を使い、custom ID / 件数を送らない。

## 理由と制約

当初の数値全面禁止から、丸め・上限を持つ録音時間だけを許可した。30秒未満は0分、360分超は過小評価となり、内容別 funnel は作れない。初期化前、終了直前、offline の欠測は許容する。旧 runtime 未付与 version を新指標の基準へ混ぜない。

送信精度より録音・保存・UI の成功を優先する。追加 field は policy・公開説明・テストを同時更新し、この設計書の要約を allowlist の拡張根拠にしない。

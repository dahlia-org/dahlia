# Desktop / Gateway の AI timeout

対象: Desktop・Gateway。採択: 2026-09-01。

## 決定と理由

Desktop が upstream より先に要約を打ち切らず、応答がない場合も有限時間で cleanup する。

| 境界 | 選択した timeout |
| --- | --- |
| 要約 turn の wall clock | 610秒。当時の Databricks model execution 上限597秒と terminal response の中継時間を含める |
| Codex app-server の通常 RPC 受付応答 | 30秒。起動・認証・model/config・thread/turn 開始を15秒から延長 |
| chat interrupt 後の terminal event 待ち | 15秒を維持。欠落時は共有接続を再生成 |
| Gateway Responses relay | 独自の wall-clock deadline を追加しない |

要約は期限到達時に interrupt / unsubscribe / cleanup を行う。固定版 Codex の SSE idle timeout（当時300秒）は最終 event からの無通信時間であり、wall clock とは別。Node の keep-alive は response 後の socket 再利用時間なので変更しない。

## 根拠と検証範囲

当時の要約270秒 / RPC15秒では、Server の補助 Databricks 呼び出し30秒や upstream execution を先に打ち切る可能性があった。値は2026-09-01の調査に基づく設計判断であり、外部 provider の恒久的な上限保証ではない。

実装は [CodexAppServerService](../../../apps/desktop/Sources/Dahlia/Services/CodexAppServerService.swift)、[GatewayService](../../../apps/server/src/ai-gateway/service.ts)、[DatabricksTokenProvider](../../../apps/server/src/databricks/token.ts)。更新時は [固定版 Codex](https://github.com/openai/codex/blob/ff29a44391deccde0aba0f8390337d7f3c319ea4/codex-rs/model-provider-info/src/lib.rs)、[Databricks limits](https://docs.databricks.com/aws/en/machine-learning/foundation-model-apis/limits)、[Node HTTP](https://nodejs.org/api/http.html) と各境界を再確認する。

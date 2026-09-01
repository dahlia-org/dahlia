# ADR-0054: AI runtime timeout を upstream execution と応答遅延に合わせる

- Status: Accepted
- Date: 2026-09-01
- Amends: ADR-0003, ADR-0029

## Context

ADR-0003 は要約 turn に 270 秒の wall-clock timeout、Codex app-server の通常 RPC に 15 秒の応答 timeout を設定した。
Dahlia Server の実装、固定版 Codex の source、Node と Databricks の upstream documentation を追跡し、次の制限を確認した。

| 境界 | 確認した制限 |
| --- | --- |
| Desktop → Codex app-server | 通常 RPC の result/error 応答は 15 秒、要約 turn 完了は 270 秒 |
| 固定版 Codex → Dahlia Server | SSE の最終 event から 300 秒で idle timeout |
| Dahlia Server の補助的な Databricks 呼び出し | model discovery と service-principal token 取得はそれぞれ 30 秒 |
| Dahlia Server → Foundation Model API | Responses relay 独自の wall-clock timeout はなし |
| Databricks Foundation Model API | model execution は 597 秒 |

Desktop の通常 RPC には app-server の起動、認証状態、model/config 読込、thread/turn 開始の応答が含まれる。15 秒は各 downstream
境界より先に Desktop だけが打ち切る余地が小さく、Server が既に補助 upstream 呼び出しへ採用している 30 秒を bounded な受付応答時間とする。
一方、interrupt 送信後に terminal event が欠落した場合の接続復旧は RPC 受付ではないため、従来の 15 秒を維持する。

## Decision

- 要約 turn の wall-clock timeout を 610 秒とする。Databricks の 597 秒上限と、その terminal response が Dahlia Server と
  Codex app-server を通って Desktop へ届く時間を含める。
- Codex app-server の RPC 受付応答 timeout を 30 秒とする。
- chat turn の interrupt 後に terminal event を待つ接続復旧 timeout は 15 秒のまま維持する。
- Dahlia Server の Responses relay には別の wall-clock timeout を追加しない。
- 固定版 Codex の stream idle timeout は wall-clock timeout と異なるため変更しない。Node の `keepAliveTimeout` は response 完了後の
  socket 再利用時間で、active SSE の deadline ではないため変更しない。

## Consequences

- Databricks が timeout を返す場合、通常は Dahlia が先に turn を中断せず upstream error を受け取れる。
- upstream が terminal response を返さない場合も、要約 waiter は 610 秒で interrupt と cleanup を実行する。
- app-server の通常 RPC は受付応答を最大 30 秒待つ。
- chat cancel 後に terminal event が欠落した場合は、従来どおり 15 秒で共有接続を再生成する。

## References

- [`CodexAppServerService`](../../apps/desktop/Sources/Dahlia/Services/CodexAppServerService.swift)
- [`GatewayService`](../../apps/server/src/ai-gateway/service.ts)
- [`DatabricksTokenProvider`](../../apps/server/src/databricks/token.ts)
- [OpenAI Codex 0.149.1 model-provider timeout defaults](https://github.com/openai/codex/blob/ff29a44391deccde0aba0f8390337d7f3c319ea4/codex-rs/model-provider-info/src/lib.rs)
- [Databricks Foundation Model API limits](https://docs.databricks.com/aws/en/machine-learning/foundation-model-apis/limits)
- [Node.js HTTP server timeout behavior](https://nodejs.org/api/http.html)

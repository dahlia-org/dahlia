# Server API 契約と生成クライアント

対象: Server・Desktop・Private Web。採択: 2026-09-09。

リリース前の一括更新として、Dahlia 所有の HTTP API を `/api/v1` に揃え、旧パス・旧 DTO の互換層を置かない。Transaction は原子的な書き込み、冪等性、revision 競合、resolve の本文一致を担うため維持する。通常 CRUD は追加しない。録音・ローカル永続化・同期キュー・既存 migration の責務と保存形式は変えない。

`apps/server/src/api/contracts.ts` と参照する Zod wire schema が契約の正本となる。`@hono/zod-openapi` が入口の型、未知キー、単値 query の重複、Content-Type を検証し、既存 service/store が現在の権限、関係、hash、revision、原子性を検証する。DTO の日時は RFC 3339、JSON フィールドは camelCase、PATCH の省略は保持、nullable な明示 null は削除を表す。storage URI と offset は DTO に含めず、内部保存形式との変換を境界で行う。

Meeting/Project の単体取得は現在の所属 Vault を解決して認可する。summary/transcript の履歴と latest、番号による取得、upload staging を別パスにする。summary-jobs の開始と retry は `202` と個別監視先の `Location` を返す。受付時の `detail` / `outputLanguage` を保存済みジョブへ確定し、その後の設定変更で変えない。

保存済みジョブの旧 detail 値は保存データの読み出し境界で正規化する。保存済み Transaction receipt も読み出し時に現行 DTO へ投影し、確定時の本文・revision・cursor と元の保存 JSON を保持する。新しい HTTP 入力で旧フィールド名を受理する互換層とは分ける。

File は JSON 予約、octet-stream の PUT、Transaction による公開の順に処理する。MIME は予約の contentType を正本とし、再送は ID・属性・サイズ・checksum を検証する。録音は session/source ごとの PUT staging と番号による公開済み read を分離する。大容量の本文はストリーミングを保ち、401 後に新しい本文を作れる呼び出しクロージャで再送する。

文字起こし chunk の staging は共有書き込み処理内で親 Meeting の所属と所有権を再確認する。同期取得後の親削除は従来どおり欠落した親を含む `409 revision_conflict` とし、Desktop の明示的な再適用による復旧を維持する。

`pnpm openapi:generate` は DB・認証情報なしで OpenAPI 3.1、Web の型と呼び出し関数、監査台帳を再生成する。同じ JSON を `/openapi.json` と npm package の `./openapi.json` で公開する。Web は openapi-typescript/openapi-fetch、Desktop は Apple swift-openapi-generator/runtime/urlsession を使う。Swift の生成先は独立した DahliaServerAPI target。生成物の nullable/date 再エンコードで hash や明示 null を変えないため、既存同期層では生成型による検証後も元の JSON bytes を保持する。

共通エラー応答は `components.responses`、同期結果・競合・変更一覧のレコード DTO は `components.schemas` を参照し、操作ごとの重複展開を避ける。nullable な DTO は `type: [object, null]` の共通定義を参照し、削除済みレコードの明示 null と省略の違いを維持する。削減は生成元で行い、公開 JSON と生成クライアントは同じ契約から再生成する。

Dahlia のエラーは RFC 9457 `application/problem+json` と安定した code、競合情報を返す。OAuth/Better Auth、OpenAI Gateway、MCP は元プロトコルを保持する。委譲はワイルドカードを OpenAPI 対応と見なさず、[全操作台帳](../../architecture/server-api-audit.md) に具体的な操作・提供条件を記録する。

CI は台帳と登録ルート、operationId、再生成差分、生成クライアントによる実 Server 呼び出し、実 JSON 応答の Zod 契約適合を検証する。Swift build/test/lint、Node/Worker のテスト・build・package 検証を行う。これらは本番 deployment や実機での録音復旧確認を代替しない。

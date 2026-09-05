# Artifact storage / API / MCP / Web

対象: Server。採択: 2026-08-29〜09-01。API の詳細は [Server README](../../../apps/server/README.md)。

## Ownership と storage

生成した HTML 等の任意 bytes を明示的に upload / 公開する出力経路とする。Artifact は作成者の personal workspace 所有、既定 private、明示 PATCH だけで public にする。他 owner には404、public read は匿名可。指定 user 共有、名前・説明・検索・履歴・versioning は追加しない。

metadata は application DB、bytes は local / S3互換 / R2 / Databricks managed Volume。認可後に Dahlia API で Range を含め streaming relay し、CSP sandbox で任意 HTML に application origin の権限を与えない。storage URL / credential は返さない。malware scan、内容分類、HTML sanitization を行うサービスではなく、公開前の内容判断は利用者が行う。

## API と ID

- raw-byte `POST /api/v1/artifacts` は最大64 MiB、Server が lowercase UUIDv7 を発行し201を返す。PUT は owner の既存 item 置換のみで、指定 ID の新規作成をしない。POST は非冪等。
- Web Crypto の乱数を共通 runtime で使い、同一 millisecond の単調化 counter と追加 dependency は持たない。ID は秘密ではなく作成時刻を推測できるため、private access は認証・owner check で守る。
- 人向けの正準 URL は `/artifacts/{id}`。POST の `viewerUrl` はこれを返し、`Location` は PUT / PATCH / DELETE に使う mutable API resource のままにする。
- 既存 GET は bytes、`Accept: application/vnd.dahlia.artifact+json` は metadata。明示的な `GET|HEAD .../{id}/content` も提供する。
- `/artifacts` と metadata list API は current owner の UUIDv7 降順・50件 keyset pagination。public の横断一覧は作らない。

## Browser read

private read は Authorization header があれば OAuth のみを検証し、不正 token から cookie session へ fallback しない。header がなければ browser session を使う。mutation に browser session を追加せず、OAuth または trusted proxy と owner check を維持する。scope は [共通 OAuth](../shared/oauth.md#scope) に従う。

## Remote MCP

stateless modern-only `/mcp` は作成、content 置換、visibility 更新、削除を既存 Artifact service と同じ認可で実行する。UTF-8 / canonical base64、decoded 8 MiB、HTTP request 12 MiB に制限し、大容量は REST に残す。作成は private、置換は content type / owner を維持し、resource link は content endpoint を指す。

accounts は MCP resource audience の DPoP-bound token を使い、issuer、audience、expiry、subject、workspace claim、scope、sender constraint を検証する。Node の CIMD は DNS resolve-once、非公開 address の拒否、connection pinning、redirect refusal を満たす secure fetch を使い、DCR は有効にしない。Cloudflare accounts はこの transport がないため CIMD を advertise せず remote client を onboarding しない。

Apps header mode は proxy 確定 identity を使い、Server OAuth challenge を重ねない。browser Origin は configured origin と一致させ、Origin のない non-browser client は許可する。tool input/output、content、token、storage URL を log しない。

## 経緯と制約

client 指定 ID と永久 reservation tombstone は、Server 採番・既存 item だけの PUT に置き換えた。削除済み ID の選択再取得を防ぎつつ永続 table を減らせるが、乱数の偶発衝突を数学的にゼロにはしない。Idempotency-Key は利用実績で必要性が示されるまで追加しない。

owner scan が実測で問題になれば複合 index を検討する。Artifact 障害は Artifact 操作だけを失敗させ、録音・保存を待たせない。会議同期は [別の canonical data 契約](../shared/sync.md) とし、Artifact API で自動 upload しない。

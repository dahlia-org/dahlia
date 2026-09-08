# Server アカウントの要約生成

対象: Desktop / Private Web / Node Server。採択: 2026-09-08。

## 実行と方法の境界

Server アカウントの要約は Server が非同期で生成・保存する。Local アカウントの内蔵 Codex 経路は維持する。
初回の `transcript` は canonical の文字起こし・画像・会議・Project を入力とし、ローカルのメモやカレンダーは送らない。
fetch ベースの既存 Responses adapter と Zod を使用し、Agents SDK は追加しない。

方法は設定の取り出し、入力収集、入力 fingerprint、モデル呼び出し、strict schema の応答検証と `SummaryDocument` への変換を担当する。
共通層は会議 ID・固定した設定・実行者・中止 signal を渡し、認可、ジョブ、lease、要約 revision、canonical 保存と同期を担当する。
組み込み方法を静的な配列から選ぶ。動的 plugin loader は持たず、未対応の方法を UI に置かない。

将来 Gemini を追加する場合は方法とアカウント設定の型を追加する。音声の取得・provider 固有応答は方法内に閉じ、ジョブ・保存・状態表示の経路は共用する。
この変更では音声転送、形式、保持期間、Gemini SDK を変更しない。音声保管は別途採択済みの [録音音声の保管](../shared/recording-audio-archive.md) に従う。

## 認証と永続化

初回は Node の Databricks backend のみで有効にする。SP token は実行時に取得し、認証済み実行者の `user_id` を
`Databricks-Ai-Gateway-Request-Tags` に設定する。Gateway の対話的 Responses は従来の OBO を維持する。
設定をジョブ開始時に固定し、token・音声・文字起こし本文・provider 応答を queue やログに残さない。

開始・状態取得は現在の Vault owner に限定する。UUIDv7 の開始 ID は冪等化に使い、異なる要求による再使用は409とする。
同じ会議には実行中ジョブを一つだけ置く。5分の lease に対し生成は4分で中止し、再起動で切れた lease も含め試行は最大3回。
成功の状態更新と canonical transaction は一つの DB transaction に含め、古い lease の worker は保存できない。
入力変更・要約 revision の競合・削除・所有権喪失では既存要約を保持する。競合を自動再実行して上書きしない。

保存時は Vault lock 下で方法の fingerprint と要約 revision を再検証し、既存の canonical transaction で会議のタイトル・説明と要約を更新する。
検索 projection と durable delta は既存経路を通す。Desktop は同期完了後に開始し、通常の remote applier で結果を受け取る。生成結果を local mutation として再送しない。
Desktop / Web の進捗は Server の状態を再取得する。Server アカウントのエクスポートは生成と分離して既存の手動操作を使う。

## 有界な入力と検証

文字起こし・画像 metadata は200件ずつ読み、文字情報は2,000,000 UTF-16 code units、文字起こし20,000件、画像metadata5,000件までとする。
上限超過は切り捨てた要約を保存せず失敗とする。画像本体は時間順に最大24枚をサンプルし、全画像の OCR / caption は文字情報に含める。
画像は1枚4 MiB、応答は2 MiBで受信を制限する。画像 block の参照先は実際に送った画像に限定する。

Node / SQLite の開始、認可、設定固定、再起動・lease、競合・削除、検索・同期と SP header をテストする。
Workers の方法一覧は空にし生成 capability は無効にする。実際の Databricks モデル権限・課金タグの集計は配置先で別途検証する。

Server transcript には Desktop の session ID / 累積 offset がないため、現時点の方式は `transcript_ref: null` のみ生成する。録音の中断時間から参照時刻を推測しない。生成タグは Desktop の canonical summary 本文取得時に既存ローカルタグへ追加し、同期イベントや summary の再送は発生させない。

モデル候補は Desktop/Web とも `/api/v1/models` の同じ一覧を使う。要約のSP呼び出しもGatewayと同じ短名→schema付き名の解決を使い、既存設定に保存された当該schema付き名は短名へ正規化してから解決する。失敗はworkerで内容・認証情報を含めず記録し、`summary_input_changed` は画面で入力更新による失敗として示す。

機能検出は `GET /api/v1/capabilities` の `summaryGeneration: { version, methods }` に統合する。登録済み方式から一覧を導出し、未対応は version 0 / 空一覧、capabilities 自体が空の場合も未対応とする。要約設定は `summary.method` と `summary.methodSettings.transcript` にまとめ、PATCH は指定した葉だけ更新する。DB列と開始済みジョブの設定スナップショットは変更しない。`outputLanguage` はアカウント設定直下に維持する。

Desktop の設定キャッシュが未取得のときは詳細度 override を送らず、Server のアカウント既定値を使う。確認画面で明示選択した詳細度は維持する。canonical 要約の新しい版を受け取ったら古いエクスポート参照を無効化するが、同じ版の再取得・キャッシュ解放では保持する。出力先のファイル自体は削除しない。

## 要約履歴と生成情報（2026-09-08）

Server は summary の全保存を `summary_versions` に本文・保存日時・作成日時と共に保持する。版番号は既存の `summaryRevision` と一致し、canonical 更新・履歴追加・生成ジョブ成功を同じ transaction で確定する。再送・失敗・競合で余分な版を作らない。既存の現在要約は forward migration で取り込み、失われた履歴や生成情報は推測しない。履歴は sync ledger と異なり自動期限削除しない。

`SummaryDocument.metadata` は Server API と Local Codex の共通 optional metadata とする。生成したシステム `generatedBy`（`server` / `local_codex`）・入力種別 `inputTypes`・詳細度 `detailLevel`・言語 `outputLanguage` と送信した `request.model` / `request.reasoning` を保持し、provider が返した `response.id` / `model` / `created_at` / `reasoning` / `usage` は OpenAI Responses API の構造で保存する。生成ジョブの方式 `method` は metadata には重複保存しない。取得できない値は欠測にし、独自計測、prompt version、入力本文・provider 応答全体の複製は追加しない。Local Codex は既存の生成経路で取得できる設定のみを埋める。編集では生成情報を外し、通常の同期・再取得では維持する。Desktop MCP の `get_meeting` と `update_meeting_summary` は同じ optional metadata schema を公開し、無変更の往復では metadata も維持する。

`GET .../summary/latest` は現在の canonical 本文を既存の text envelope と hash、任意の manifest で返す。Desktop の Server 要約本文読取りは latest に統一し、同期 metadata と revision が異なるときは再同期して再取得する。未送信編集の保護と通常の remote applier を維持し、過去版を最新として採用しない。差分適用後に要約自身の読取り可否を再検証し、無関係な保留差分があっても安全な最新本文を取得する。Desktop が表示するのは最新だけであり、既存の現在本文キャッシュを利用する。

`GET .../summary` と `GET .../summary/{revision}` を追加し、Web の要約タブで過去版を閲覧できる。現在の Vault 読取り権限を継承するため共有メンバーも閲覧できる。PostgreSQL は FORCE RLS、全 runtime は共通認可を適用する。要約削除は全履歴の削除も意味し、会議・Vault 削除でも履歴を削除する。Web の確認文に全版削除を明示する。横並び比較・復元・Gemini 生成の実装は今回の対象外とする。

HTTP の会議詳細（Vault 配下と ID 解決用の両経路）は会議情報と同期状態だけを返し、summaryTitle / summaryDocument / summaryCreatedAt を除く。summaryRevision、contentOmitted、hasSummary、録音状態は保持する。snapshot / delta は常に本文なしとし、content query は使わない。file 補完は OCR / caption と revision を含む個別 metadata を使う。DB 正本と Server MCP の要約込み読取り契約は変更しない。

要約一覧は GET summary、本文は GET summary/latest または数値 revision の GET summary/{revision} とする。旧 versions 経路と text/summary は互換 alias を残さず削除し、生成 POST と固定 job 経路は変更しない。公開 Desktop v0.21.0 に利用箇所はない。開発版 consumer は更新が必要であり、migration、Server と Web asset の同時更新、Desktop の順で適用する。既に開いている旧 Web は再読み込みが必要になる。

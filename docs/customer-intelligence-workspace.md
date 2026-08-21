# Customer intelligence workspace

Dahlia の「顧客インテリジェンス」画面は、選択中の Vault にある顧客の組織、人物、会話の流れ、AI の
分析結果を一か所で確認する bounded workspace です。設定の「詳細」→「ベータ機能」で
「顧客インテリジェンス」をオンにすると、メインツールバー、メニューバー、`⇧⌘O` の入口が表示されます。
この設定は入口の表示だけを切り替え、データ処理や MCP を無効化しません。

## 画面

- 左ペインは「概要」「組織」「人物」「Projects」「トピック」「インサイト」の機能別ナビゲーションです。
  顧客企業はサイドバーに並べず、共通ツールバーの顧客スコープで「すべての顧客」または一つのルート組織を
  選びます。最後に選択した機能、顧客スコープ、Table の密度は次回も復元されます。
- 「概要」は、Vault 全体では顧客別カード、個別顧客では人物、Projects、トピック、Meeting、未確認
  インサイトの360°サマリーを表示します。
- 「すべての顧客」の組織画面は顧客カードのグリッドです。カード全面を選択すると顧客スコープを変更し、
  一つのルートだけを自動配置した組織図を開きます。子部門は展開時に50件ずつ読み込みます。
- 人物、Projects、トピック、インサイトは macOS の Table で検索、選択できます。右インスペクタは
  閲覧と関連先への移動に限定し、人物・所属・Project・Topic の変更は明示的な専用シートで行います。
- トピックの根拠 Meeting はクリックするとメインウインドウで開きます。インサイトは「未確認」を優先した
  確認受信箱で、確認済みへの変更を明示的に行います。
- Project の名称、親、種別、説明はこの画面で編集できます。Meeting の移動、Project 階層の削除、
  要約ファイル処理は「Projectsで管理」からメインウインドウのProject管理を開きます。
- ルート Organization のインスペクタには、参加者の分類に使うメールドメインを表示します。同じドメインを
  複数のルート Organization で共有できます。別の1組織に割り当て済みの場合は、非破壊の共有追加または
  ドメイン、人物、部署、Project、Topic、Insight の参照を選択中の Organization へ移す統合を選びます。
  すでに複数組織で共有されている場合は共有追加だけを行います。
  統合先の名称と主ドメインを維持し、重複する所属や参照では統合先の情報を優先して、元の Organization
  を削除します。統合先に主ドメインがない場合は、元の Organization の主ドメインを引き継ぎます。
- Organization と部門には説明を保存でき、作成・編集・詳細表示と組織検索で利用できます。
- Organization、暫定人物、Topic の削除はインスペクタ最下部の Danger Zone にだけ表示します。
- ズームは50〜200%です。ツールバー操作に加えてトラックパッドのピンチで連続的に変更できます。
  座標は保存せず、親子関係から毎回派生します。
- Topic を選ぶと直接参照された組織・部門と、参照人物の所属部門を表示して祖先を展開し、それ以外を弱く
  表示します。根拠 Meeting の日時と note は右ペインで確認できます。

人物はキャンバスのノードではありません。所属と役割は Organization の文脈で管理します。Topic の Meeting
参照には、その会議で進んだ内容を短い note として必ず保存します。最終議論日時、Meeting 数、関係部門数は
参照履歴から計算され、固定進捗率や sentiment は持ちません。

## 顧客スコープ

個別顧客スコープは、選択したルート Organization と全子孫を含みます。人物はその範囲への Membership を
持つ Contact だけです。Project、Topic、Insight は、範囲内 Organization または Contact への明示的な
参照を持つものだけを含みます。Project や Meeting を経由した推測的な関連付けは行いません。一覧、検索、
件数、概要はすべて同じ規則を使います。

## AI で整理

「AIで整理」は既定90日の期間、組織 UUID、任意の Project UUID を含む依頼をチャット入力欄に準備します。
自動送信しません。AI は保存済み要約を先に読み、必要な場合だけ transcript を確認します。共有ドメインの
人物はドメインだけで所属を決めず、議事録などの証拠に基づいて `set_contact_organization_membership` で
明示的に所属させます。

新しい AI チャットの上部には「直近30日のミーティングとProjectを整理」ショートカットがあります。選択時に
直近30日の開始・終了日時を確定して依頼を自動送信し、`projects-optimizer` が Meeting、Project 階層、説明、
Meeting assignment を整理します。この30日はショートカット固有の明示指定であり、期間を指定せずに
`projects-optimizer` を依頼した場合は既定の90日を使用します。

アプリ内チャットには、この整理手順を層ごとに固定した preset skill が同梱されています。人物・組織・所属は
`contacts-organizations-curator`、継続トピックは `conversation-topics-curator`、インサイトは
`insights-curator` が担当し、依頼内容に応じてチャットが自動で選択します。3つは互いを参照しないため、
「コンタクトだけ」「トピックだけ」のように単独でも、まとめてでも実行できます。トピックとインサイトの
skill は、参照先の人物や組織が1件足りない場合だけ最小限作成し、名寄せ・所属・ドメイン・階層の整理は
`contacts-organizations-curator` へ残作業として報告します。AI が作成したインサイトは未確認のまま残ります。
Meeting と Project の関連付けは1次情報側の扱いで、3つの skill はいずれも変更せず、`projects-optimizer`
の責務です。

Organization の名称と説明、Contact の表示名、Topic のタイトルと現在の状態、Insight の内容は画面から直接
編集でき、Dahlia は以前の版を保存しません。skill はこれらを利用者が確定した値として扱い、空欄には自由に
書き、既存の記述は保持したうえで追記または簡潔化だけを行います。記述を削除または矛盾させる変更は確認を
求めてから実行し、変更した場合は変更前の内容を逐語で報告します。`projects-optimizer` が Project の説明に
対して行う扱いと同じです。

AI は書き込み前に `query_*` または `get_*` で現在値と revision を取得し、次の単純なツールを順番に呼びます。

- 正準レコード: `create_*`、`update_*`、`delete_*`
- 関係: `set_*`、`remove_*`
- Contact 統合: `resolve_contact`

一回の呼び出しが変更するのは一つのレコードまたは一つの関係だけです。一件が失敗しても、それまでの成功分は
維持され、独立した後続処理を続けられます。失敗した対象だけを再取得し、最新 revision で再試行します。
proposal、import、batch、永続 idempotency staging は使いません。AI チャットの承認方法はタスクごとに選択します。
「承認を求める」では必要な操作をチャット内の承認プロンプトとして提示し、「代わりに承認」は ChatGPT
Subscription のみで利用できます。どちらも `workspaceWrite` の範囲で動作します。MCP の書き込みでは、対象の
server、tool、引数を確認して呼び出し1回だけを許可できます。承認はチャット本文への返答ではなく、その
プロンプトのボタンで行います。「フルアクセス」は承認プロンプトなしで filesystem と network を利用できるため、
警告表示された選択肢を明示的に選んだタスクだけに適用します。

暫定人物はメールがない Contact です。メールだけで Contact を作る場合、表示名にはメールの `@` より前を
使用します。未使用メールが判明した場合は `update_contact`、既存 Contact と同一人物だと判明した場合は
`resolve_contact` を使用します。Organization、Contact、Topic、Insight の削除は MCP
に公開しますが、Meeting participant の変更は引き続き公開しません。

削除も事前に現在の revision を取得してから1件ずつ実行します。Organization は子 Organization と所属
Contact がない葉だけを削除できます。Contact は Membership、Meeting participant、Project、Topic、
Insight の参照がすべて解除されている場合だけ削除できます。条件を満たさない場合は
`resource_in_use` と参照種別・件数が返るため、解除可能な関係を個別に外してから再取得します。

## MCP

読み取りセッションでは Organization、Contact、Topic、Insight、Project、Meeting を `query_*`／`get_*`
で取得できます。`query_organization_chart` は一つのルートを最大500ノードまで返し、
`nodes_truncated` が絞り込みの必要性を示します。Organization の読み取り応答は `description` を含み、
`query_organizations` は名称、説明、ドメインを検索します。

`--write` セッションだけが以下を追加公開します。

- `create_organization` / `update_organization` / `delete_organization`
- `create_contact` / `update_contact` / `delete_contact` / `resolve_contact`
- `create_conversation_topic` / `update_conversation_topic` / `delete_conversation_topic`
- `create_insight` / `update_insight` / `delete_insight`
- `set_organization_domain` / `remove_organization_domain`
- `set_contact_organization_membership` / `remove_contact_organization_membership`
- `set_project_resource_reference` / `remove_project_resource_reference`
- `set_conversation_topic_resource_reference` / `remove_conversation_topic_resource_reference`
- `set_insight_resource_reference` / `remove_insight_resource_reference`
- `set_meeting_project_assignment` / `remove_meeting_project_assignment`

`set` は作成または metadata 更新、`remove` は関係だけの削除です。同じ値の再設定や削除済み関係の再削除は
成功し、`changed: false` を返します。
Contact 応答の `email` は常にキーを持ち、暫定人物では `null` です。
Topic と Insight の削除は所有する参照だけを削除し、参照先の Meeting、Organization、Contact、Project
は残します。

開発途中の旧スキーマを適用済みの QA データベースは、Dahlia 起動時の
`v29_customerIntelligenceDirectCRUD` で現在の Insight 列と cleanup trigger へ前方修復されます。
続く `v30_organizationDescription` は既存 Organization を保持したまま説明列を追加します。
`v33_sharedOrganizationDomains` は既存ドメイン行を無変換で保ちながら共有を可能にします。MCP は v33
完了前のデータベースを開かず、Dahlia を一度起動してアップグレードするよう案内します。

設定の「カレンダー」にある「参加者を組織へ自動で紐付ける」は既定でオンです。オフでも Contact、
Meeting participant、初出ドメインの Organization は作成されます。設定にかかわらず、複数組織で共有する
ドメインからは Membership を自動作成しません。

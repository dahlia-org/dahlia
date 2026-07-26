# Customer intelligence workspace

Dahlia の「組織」画面は、選択中の Vault にある一社の組織階層と、その各部門で進む会話を俯瞰するための
bounded workspace です。メインツールバー、メニューバー、または `⇧⌘O` から開きます。

## 画面

- 左ペインはルート組織を検索し、未所属人物を表示します。
- 中央は選択した一つのルートだけを自動配置します。子部門は展開時に50件ずつ読み込みます。
- 右ペインは人物、Project、継続トピック、Meeting 履歴、AI提案を表示します。
- ズームは50〜200%です。座標は保存せず、親子関係から毎回派生します。
- Topic を選ぶと直接参照された組織・部門と、参照人物の所属部門を表示して祖先を展開し、それ以外を弱く
  表示します。根拠 Meeting の日時と note は右ペインで確認できます。

人物はキャンバスのノードではありません。所属と役割を右ペインで管理します。Topic の Meeting
参照には、その会議で進んだ内容を短い note として必ず保存します。最終議論日時、Meeting 数、関係部門数は
参照履歴から計算され、固定進捗率や sentiment は持ちません。

## AI で整理

「AIで整理」は既定90日の期間、組織 UUID、任意の Project UUID を含む依頼をチャット入力欄に準備します。
自動送信しません。AI は保存済み要約を先に読み、必要な場合だけ transcript を確認します。通常の分析は
`propose_customer_intelligence_changes` までで止まり、正準データは変わりません。

提案には差分、field expectation、根拠、依存関係、revision があります。複数選択の apply は依存順の
単一 transaction で実行され、一件でも stale・対象消失・期待値不一致なら全件をロールバックします。
`meeting_participants` を変更する proposal operation は存在しません。
既存データを変更する proposal では、変更対象フィールドすべての expectation が必須です。Topic の参照を
置き換える場合は `get_conversation_topic` の `references_expectation` をそのまま使用します。
提案バッチ、文字列、依存関係、根拠、Topic 参照には上限があり、重複参照や Meeting note の欠落は review
queue に保存する前に拒否されます。

暫定人物はメールがない Contact です。メールが判明した時は同じ Contact を特定済みにするか、既存の
特定済み Contact へ参照を統合します。統合前の UUID を payload から参照する未適用提案は
`contactResolved` で stale になります。Contact、Organization、Topic の削除は UI／Repository の明示操作
だけに限定され、MCP proposal からは実行できません。

## MCP

読み取りセッションでは次を利用できます。

- `query_organization_chart`
- `query_conversation_topics`
- `get_conversation_topic`
- `query_customer_intelligence_proposals`
- Organization／Topic filter を持つ `query_meetings`

`--write` セッションだけが proposal の作成、適用、却下を公開します。Meeting 限定セッションは従来どおり
`get_meeting` だけです。Contact 応答の `email` は常にキーを持ち、暫定人物では `null` です。
組織図の一回の応答は最大500ノードで、`nodes_truncated` が depth や子件数を絞る必要があるかを示します。

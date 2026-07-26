# 顧客インテリジェンス、Ontology、Insight に関する調査

> Implementation note (2026-07-27): 「組織」画面は一社のルートに限定した bounded hierarchy viewer として
> 実装した。巨大な graph canvas、graph DB、自由座標は導入せず、人物は inspector に置く。AI の判断は
> 正準データから分離した reviewable proposal とする。詳細は
> [ADR 0012](../adr/0012-reviewable-customer-intelligence-workspace.md) を参照。

- 調査日: 2026-07-26
- 状態: v1 の設計判断に反映
- 対象: Dahlia の議事録・Calendar attendee から構築する組織、人物、プロジェクト、用語、AI示唆のローカルデータ基盤

## 結論

Dahlia の v1 では、汎用の `ontology_entities` テーブルやグラフDBを正本にしない。

他社製品に共通する有用な構造は、すべてを同じ柔軟なスキーマへ押し込むことではなく、次の層を分離することである。

1. 人、組織、会議、プロジェクトなど、識別と更新規則が安定した正準オブジェクト
2. 所属、参加、案件との関係など、型が明確なリンク
3. 会話や活動履歴から得られる鮮度・頻度などの派生シグナル
4. 出典、確度、rank、review状態を持つ、再計算可能または人の確認を要する知識
5. AIまたは人が実際の正準データを変更するための、示唆とは分離された明示的な操作

したがって、Dahlia では Organizations、Contacts、Projects、Meetings、Glossary terms を正準テーブルとし、確定関係を専用の関連テーブル、まだ仕様が固まっていないAI示唆を `insights` と汎用参照テーブルへ分離する。

Insight の承認は正準テーブルへの書き戻しを意味しない。Organization、Membership、Project referenceの変更は、将来も別の明示的操作として扱う。これにより、AIの出力形式やrank方式を変更しても、顧客データの主キーや安定カラムを移行せずに済む。

## 調査結果

### Databricks Genie Ontology

参照:

- [Chat in Genie One / Genie Ontology](https://docs.databricks.com/aws/en/genie-one/chat)

確認できた内容:

- Genie Ontology は、table、query、dashboard、document、connected app から短い knowledge snippet を抽出する。
- snippet は metric definition、authoritative source、business rule などを表す。
- source、利用頻度、freshnessを基にauthority scoreを持ち、質問ごとに関連snippetをrankし、競合を解決する。
- Unity Catalog permissionで閲覧可能なsnippetを制限し、回答から利用したknowledge sourceへcitationを表示する。
- 2026-07-26時点ではPublic Previewである。

Dahliaへの示唆:

- 短文の知識単位、出典、rank、freshnessは有用だが、rankやsnippet typeはまだDahliaの安定スキーマにすべきではない。
- v1では `insights.content` を短文の知識単位として利用できるようにし、rank、confidence、model、prompt、provenanceなどは `metadataJSON` に保持する。
- sourceとの関係は本文中のUUIDではなく、`insight_references` で明示する。
- 独立した `knowledge_snippets` テーブルは、生成・競合解決・再評価の要件が固まった時点で再検討する。

### Palantir Ontology

参照:

- [Ontology overview](https://www.palantir.com/docs/foundry/ontology/overview)
- [Object edits and materializations](https://www.palantir.com/docs/foundry/object-edits/overview)

確認できた内容:

- Ontologyは実世界の対象をobjectとpropertyで表し、object間をlinkで接続する。
- semanticなobject/linkと、変更を実行するaction/functionを別概念としている。
- Actionはobject propertyやlinkの変更を行う明示的なtransactionで、権限・validation・governanceの対象となる。
- Object ViewやObject Explorerは、正準objectを起点に関係や履歴を辿る。

Dahliaへの示唆:

- AIによる「提案」と、正準オブジェクトを変更する「操作」を分けるべきである。
- Project、Meeting、Organization、Contactを一つの汎用object tableへ置き換えるより、既存の型付きテーブルを正本として維持する方が、GRDB、FK、Vault境界、既存MCPとの整合性が高い。
- 多様なリンクだけを参照テーブルで拡張し、リンク挿入時には対象の型・存在・Vault一致を検証する。

### Glean Knowledge Graph

参照:

- [Knowledge Graph](https://docs.glean.com/security/knowledge-graph)

確認できた内容:

- Knowledge Graphの中核をContent、People、Activityの3層としている。
- Peopleは複数サービスのidentity、role、team、organizational relationshipを統合する。
- Activityはinteraction、history、engagementを扱い、検索のpersonalizationやrelevanceへ利用する。
- content単位のpermissionと、個人データの分離・集約時のprivacy thresholdを明示している。

Dahliaへの示唆:

- ContactのidentityとMeeting参加履歴を分け、last interactionなどは履歴から計算する。
- ローカルv1ではContactをVault単位にし、別Vaultの表示名や関係を共有しない。
- 将来クラウドで複数ユーザー・複数Vaultを集約する場合は、クラウド側の安定UUIDとemail identity解決を追加し、ローカルUUIDをそのまま全テナント共通の人物IDとみなさない。

### Gong Revenue Graph

参照:

- [Gong Revenue Graph](https://www.gong.io/platform/revenue-graph)

確認できた内容:

- call、email、meeting、CRM contactなどのinteractionをpeople、account、dealへ対応付ける。
- interactionそのものと、AIが利用する構造化contextを分離している。
- CRMとの双方向同期やagent actionも提供するが、正本への反映は製品の明示的なintegrationとして扱われる。

Dahliaへの示唆:

- Meeting participantをContactへ、ContactのdomainをOrganizationへ対応付けるだけでも、議事録を顧客・関係者単位で横断する基礎になる。
- ProjectとOrganizationを単一FKで固定せず、発注元、利用部門、意思決定者などのrelation labelを持つ参照にする。
- v1ではcalendar-linked Meetingだけを取り込み対象とし、全Calendarや全メールを先回りしてContact化しない。

### Affinity Relationship Intelligence

参照:

- [Relationship Intelligence](https://www.affinity.co/product/relationship-intelligence)
- [Affinity CRM](https://www.affinity.co/product/)

確認できた内容:

- emailとcalendarに隠れたwho-knows-whom、recency、frequencyからrelationship strengthを提示する。
- email/calendar同期からpeople/company profileを自動作成し、interaction historyを蓄積することを製品ページで説明している。

制約:

- 公開された製品ページは概念とUI上の価値の説明が中心で、identity merge、データモデル、score式、削除整合性の一次仕様は確認できなかった。
- したがって、具体的なスキーマやscore計算の根拠には使用しない。

Dahliaへの示唆:

- 最終接点はContactの可変カラムではなくMeeting履歴から計算する。
- recency/frequency scoreは将来の派生Insight候補であり、v1のContact安定カラムへ追加しない。

### Gainsight Customer 360

参照:

- [360 Overview](https://support.gainsight.com/gainsight_nxt/07360/About/360_Overview)
- [View Company Hierarchy](https://support.gainsight.com/gainsight_nxt/07360/User_Guides/View_Company_Hierarchy)

確認できた内容:

- C360を顧客情報のcentral hubとし、summary、health、people、relationship、company hierarchy、timeline、success planを同一顧客の文脈で表示する。
- Person hierarchyとInfluencer relation、親子会社と兄弟会社を含むCompany Hierarchyを扱う。
- Relationship自体をobjectとして持ち、複雑な顧客構造のconnection pointを表現できる。

アクセス状況:

- 2026-07-26の確認では本文を閲覧できた。サイトにはログイン導線もあるため、将来本文が認証必須になった場合は「参照不可」と記録し、取得済み内容を最新仕様と断定しない。

Dahliaへの示唆:

- OrganizationとUnitを同じ階層テーブルで扱い、Contactとの所属を多対多にする。
- 日本企業の兼務を表せるよう、primary membershipを設けない。
- 将来のUIはOrganization/Contact詳細を起点に、hierarchy、people、projects、timeline、accepted insightを個別sectionで構成するのが自然である。

### Microsoft Dynamics 365 Relationship Intelligence

参照:

- [Relationship intelligence FAQs](https://learn.microsoft.com/en-us/dynamics365/sales/faq-relationship-intelligence)
- [Enable and configure relationship intelligence](https://learn.microsoft.com/en-us/dynamics365/sales/enable-ri)

確認できた内容:

- email、phone call、appointmentをrelationship insightの入力にする。
- relationship healthはactivity、recency、engagement、sentimentを使用する。
- who-knows-whomはemail/appointmentのfrequency、拡張構成ではrecencyも使用する。
- activity typeの重みや期待communication frequencyを管理者が設定できる。
- Microsoft 365データの利用には同期・同意・ライセンスなどの境界がある。

Dahliaへの示唆:

- Meeting履歴から計算できる事実と、重みや閾値を伴うscoreを区別する。
- v1ではmeeting countとlast interactionを事実として返し、relationship healthやsentimentを安定カラムにしない。
- 将来scoreを導入する場合は、計算version、対象期間、入力件数、生成日時をprovenanceとして残す。

### Salesforce Data Cloud

参照を試みたページ:

- [Data Graphs](https://help.salesforce.com/s/articleView?id=sf.c360_a_data_graphs.htm&language=en_US)
- [Insights](https://help.salesforce.com/s/articleView?id=data.c360_a_insights.htm&language=en_US&type=5)

アクセス状況:

- 2026-07-26の取得では、両ページとも本文ではなく `Loading` / `CSS Error` のみ返り、一次資料の内容を確認できなかった。
- 検索結果や第三者解説だけでData GraphやInsightの詳細仕様を補完することはしない。
- 今回のv1判断は、取得できた他社一次資料とDahlia自身の要件を根拠にする。

## 比較

| 観点 | 他社で確認した傾向 | Dahlia v1 |
| --- | --- | --- |
| 正準entity | people、organization/account、deal/project、activityを区別 | 既存のMeeting/Projectと新規Organization/Contactを型付きテーブルで保持 |
| Identity | 複数sourceの統合、tenant/permission境界 | ContactはVault単位のUUID、v1はprimary email 1件 |
| Organization | company hierarchy、team/role、people map | Organization/Unitを同一階層、Contactとは多対多 |
| Interaction | email、calendar、callをpeople/accountへ接続 | calendar-linked MeetingのparticipantだけをContactへ接続 |
| Relationship signal | recency、frequency、engagement、sentiment | meeting countとlast interactionのみ履歴から計算 |
| Knowledge | snippet、business rule、metric、authoritative source | Glossary termとInsightを分離 |
| Rank/freshness | source、usage、freshness、重みで派生 | `metadataJSON`。安定カラムにしない |
| Provenance | citation、source link、permission | typed referenceで対象を示し、詳細はmetadata |
| Review/write-back | proposalとactionを権限付きで分離 | accepted Insightは正準データを変更しない |
| 360 UI | entity詳細にhierarchy、people、timeline、insightを集約 | v1はDB/MCP基盤。UIは後続 |

## v1 の設計判断

### 採用

- `contacts` はUUIDv7主キーとし、`vaultId` と正準化済み `email` の組を一意にする。
- 複数emailとContact mergeは導入せず、別emailは別Contactとして扱う。
- `organizations` はOrganizationとUnitを `nodeKind` で区別し、親子関係を同じテーブルに持つ。
- Organizationは複数domainを持てる。初回自動作成時のnameは `domainName` とし、その後の同期はユーザー変更済みnameを上書きしない。
- public mailboxの判定は依存関係や通信を増やさないcurated listによるbest effortとし、未知のproviderを完全には分類しない。
- Contactの所属は多対多とし、兼務を表現できるようにする。
- ProjectはOrganization/Unit/Contactを汎用resource referenceで参照し、専用の `organizationId` を持たない。
- Glossary termは安定した用語・定義、Insightは未確定のAIまたは人の示唆として分離する。
- Insight/Glossary/Projectの汎用参照は、INSERT/UPDATE時の存在・Vault検証と、参照先DELETE時のtrigger cleanupを持つ。
- read-only MCPからOrganization、Contact、Project resource、Insight、GlossaryをVaultスコープで取得できるようにする。
- MCPのcursorはVaultとfilter条件に束縛し、nested referenceは上限とtruncation表示を持たせる。

### v1では採用しない

- 汎用 `ontology_entities` / `ontology_edges` を正本にする設計
- graph database
- 独立したsnippet、rank、confidence、modelカラム
- AIによるOrganization、Membership、Project relationの自動確定
- Contactの複数email、merge、split
- relationship health、sentiment、engagement score
- Calendar全件または既存Meetingのbackfill
- AIによる定期・自動生成

## 将来の拡張条件

### Contact統合

複数emailまたはContact統合を追加する場合、クラウド側または新しい `contact_emails` テーブルでcanonical Contact UUIDを決める。統合処理は同一トランザクションで、少なくとも次の参照を書き換え、一意制約衝突を重複排除する必要がある。

- `meeting_participants.contactId`
- `organization_memberships.contactId`
- `project_resource_references` のContact参照
- `insight_references` のContact参照
- `glossary_term_references` のContact参照

ローカルのContact UUIDはVault内の安定IDであり、クラウド全体の人物IDとしてそのまま採用しない。クラウドは独自のUUIDを発行し、source Vault/local UUID/emailをidentity evidenceとして保持できる。

### Knowledge snippet

次が必要になった時点で、Insightとは別のsnippetモデルを再検討する。

- 同じ知識の複数sourceを集約する
- source authority、利用回数、freshnessを再計算する
- 競合する知識を解決する
- 質問ごとのrankと利用citationを保存する
- permissionによって利用可能なknowledgeを変える

その場合も、生成されたsnippetをOrganizationやContactの専用カラムへ埋め込まず、正準entityへの参照として実装する。

### UI

管理画面を追加する場合は、単一の巨大なgraph canvasから始めず、Organization/Contact詳細を起点に次を段階的に表示する。

- Organization hierarchyとdomain
- 所属Contact
- 関連Projectとrelation label
- Meeting timelineとlast interaction
- accepted Insight
- Glossary term

これにより、C360型の俯瞰と、個別関係の根拠確認を両立できる。

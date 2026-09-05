# 顧客情報の正準モデルと更新

対象: Desktop・local MCP。採択: 2026-07。現在の schema / tool 詳細は [Customer intelligence workspace](../../customer-intelligence-workspace.md)。

## 正準モデルと AI の主張

安定した顧客情報は型付き table、AI の仮説・rank・confidence・provenance は Insight と metadata に分離する。Insight の Boolean acceptance は正準 record を変更せず、write-back は別の明示操作にする。generic ontology を正本にせず、変化しやすい関連だけ typed polymorphic reference を使う。

- Contact は Vault 内の UUID identity と nullable primary email。email があれば Vault 内で一意だが、Vault 横断 registry / 名前補完はしない。
- Organization / unit は immutable nodeKind と parent による共通階層。root は Organization、query / mutation は32 edge上限。Project の2段階制限とは別。
- domain は root Organization に付け、存在する場合は supported writer が必ず1つの primary を維持する。削除時は最古の残存 domain を昇格する。membership は many-to-many、primary membership は持たない。
- calendar 由来 `meeting_participants` は role / response / source を保存する。Project resource、Topic、Insight は typed reference を使い、target の存在と同一 Vault を trigger で検証し、target 削除で参照を除去する。unlabeled relation は空文字にして unique constraint で重複を防ぐ。
- Topic の status / progress は保存せず、最終議論、meeting 数、関連組織数を参照履歴から導出する。

email / domain は trim、lowercase、ASCII 検証を共通 RuntimeSupport で行う。local part の小文字化は実用上の選択で、IDNA は導入しない。非 ASCII は ingestion で skip、明示 write で拒否する。domain は `@` 以後の完全 host で、registrable domain へ縮約しない。

## Calendar ingestion

最初の非 public domain の観測で domain 名を初期名とする Organization を作り、以後 user 編集名を上書きしない。public mailbox は Contact だけを作る。provider list は手動保守の best-effort で完全性保証はなく、誤分類は明示操作で修正する。

ingestion は meeting 保存後、録音では capture 成功後に schedule する。失敗しても成功済み meeting を rollback せず録音開始を止めない。過去 meeting / 全 calendar を自動 backfill しない。Contact の interaction は declined participant を除き、meeting.createdAt に基づいて導出する。

## Domain 共有と統合

同じ domain を複数 root に割り当てられるよう `(vaultId, domainName, organizationId)` を key とする。観測日時は共有する全 Organization で更新する。自動 membership は既定有効の設定だが、複数 owner の domain では必ず抑止する。設定無効でも Contact / participation / 初回 Organization 作成は続ける。

他の owner が1つなら UI は非破壊の共有追加と merge を選べる。複数なら共有追加だけ。MCP は domain set / remove と明示 membership を提供し、merge は UI の root 同士だけで行う。

merge は source domain、両 revision、review 済み impact count を再検証し、domain、membership、descendant、Project / Topic / Insight reference を1 transaction で移してから source を削除する。target の名前・階層・primary・重複 metadata を優先し、target に primary がなければ source を継承する。domain 日時は earliest first / latest last に統合し、source の非衝突関係は保持する。conflict は全 rollback して再 review。source 名の消失を明示し、review sheet を元 Vault / target に固定する。

## MCP と UI

record は query/get/create/update/delete、relation は query/set/remove の小さな tool で操作する。update/delete は current revision、未指定 property は保持。set/remove の達成済み状態は changed:false、存在しない record の delete は not_found。Contact merge は専用 resolve_contact として残す。

1 call は1 record / relation の atomic transaction。Organization delete は空 leaf、Contact delete は membership / participation / Project / Topic / Insight 参照がない場合だけ許可し、resource_in_use と件数を返す。Topic / Insight delete は自身の reference だけを除去する。calendar participation の mutation、Project delete、proposal DSL / batch / import staging は公開しない。

複数 call 全体は atomic ではない。失敗分だけ再取得・retryし、先行成功は保持する。DB writer 待機は最大5秒。承認は [Chat approval](chat-approval.md) に従う。

query は最大100件、Vault / filter に結び付く keyset cursor。nested relation は100件と truncation flag、recent Contact meetings は25件。メール等の個人情報は選択 Vault の agent に渡り得るため、identity / disambiguation 以外で不要に反復しない。

Organization UI は単一 customer root の bounded hierarchy viewer。展開時に子を読み、座標を保存せず自動配置する。Contact は inspector、Topic focus は無関係 node の dim 表示だけで cross-link を描かない。

## 経緯と制約

初期の schema-first / read-only から単数 CRUD に進み、Glossary と proposal / import staging は未リリース schema から削除した。独立した用語 store は transcription や AI context を改善しなかったため、必要になればその入力として再検討する。

domain の一意 owner が別会社を誤統合したため共有 domain を導入した。email primary key、Vault 横断 Contact registry、汎用 entity/edge、永続 graph 座標、sentiment / synthetic progress は採用しない。複数 email、一般的な merge / split、cloud-wide person identity は別の設計判断を要する。

未リリース QA schema の移行・整理履歴を現在の migration 編集許可とは扱わない。現在の schema gate は機能文書と実装を参照する。

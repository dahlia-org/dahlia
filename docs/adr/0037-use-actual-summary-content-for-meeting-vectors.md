# ADR-0037: meeting vector は title と実際の summary コンテンツから生成する

## Status

Accepted; amends ADR-0035 and builds on ADR-0001 and ADR-0034.

## Decision

- meeting vector は、trim 済み meeting title、`SummaryDocument.description`、section body の実コンテンツから生成する。
- 有効な `SummaryDocument` の description または section body に空白以外の文字が1文字でもあれば対象とし、固定の最小文字数は設けない。
- meeting title だけ、Meeting description だけ、calendar、tag、project path だけでは meeting vector を生成しない。
- project vector は解決済み project path と project description から生成する。project 類似度は meeting 自身の類似度閾値を通過した候補の順位補正だけに使い、候補を追加しない。
- 文書構成の変更は configuration hash で検出し、既存索引は明示的な再構築まで FTS に縮退する。

## Consequences

- 短い summary も内容があれば Neural 検索の対象になる。
- 未要約 meeting や空の summary は、汎用的な title だけの重複 vector を作らない。
- Meeting description や project 文脈の変更は、meeting vector の再生成を要求しない。

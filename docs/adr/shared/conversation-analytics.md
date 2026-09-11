# 会話分析の Server ownership

対象: Desktop / Server。採択: 2026-09-11。

## 決定

会話分析は、録音音声を保存している Server Account の owner 専用ベータ機能とする。Desktopでの生成・キャッシュ・録音後の
再計算予約を廃止し、Desktopは表示中の文字起こしIDと版を指定してServerの集約済み結果だけを表示する。取得中に対象版が
変わった場合は古い結果を破棄する。

結果は immutable な文字起こし版からタブ表示時に同期計算し、分析テーブルやジョブは追加しない。文字起こし本文から直ちに
求められる空白除外Unicode書記素数だけを `transcript_segments.normalized_character_count` にnullableで保存する。`NULL` を既存の
未計算行として初回分析時に補完するため、別の `text_metrics_version` は持たない。

録音集合も版の生成metadataに固定する。Desktop生成runは `recordingSessionId`、Server生成runは録音番号・音源・checksumを
照合し、会議全体の録音一覧から推測しない。参照metadataがない旧版や参照音声を照合できない版は分析不可とする。

初版は文字数、発話時刻、音源、録音時間から求める指標だけを対象にする。Geminiによる音響分析は実装せず、必要になった時点で
録音checksum集合・モデル・schema versionをキーにした文字起こし版とは独立のテーブルとして設計する。

## 理由

文字起こし処理を後から切り替えると発話区切りが生成ごとに変わるため、Desktopの最新本文を入力にした会議単位キャッシュは
どの版の結果か保証できない。Serverは版付き文字起こしと確定音声の両方を認可境界内で参照でき、版単位の再現性を保てる。
nullableな数値だけで既存行と新規行を区別できるため、計算方式の版列は現時点では不要である。

## 互換性

Local Accountとread-only memberには公開しない。Desktopの登録済みDB migration、旧分析テーブル、旧音響列は変更・削除せず、
新しい実行経路から参照しない。将来、文字数の定義を変更する必要が生じた場合にだけ、新列または明示的な再計算方式を追加する。

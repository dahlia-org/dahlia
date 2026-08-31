# ADR-0052: Desktop の Dahlia アカウント接続を Vault から分離する

- Status: Accepted
- Date: 2026-08-31
- Amends: ADR-0051
- Builds on: ADR-0043

## Context

ADR-0051 の Desktop OAuth は単一 credential をアプリ全体で保持していた。Dahlia Cloud／Server の接続は Vault の所有者ではなく、
同じ接続を将来複数 Vault の付加機能から利用できる必要がある。一方、現在は接続を消費する sync API がなく、効果のない Vault 割り当てを
先行して永続化・表示すると利用者に誤解を与える。

将来想定する meeting sync は文字起こしや議事録の任意の付加機能であり、チーム共有、共同編集、権限管理、音声のクラウド処理・保管を
この決定に含めない。録音、文字起こし、閲覧、検索はアカウントやネットワークなしで完結させるため、現行の PRODUCT tenet と衝突しない。
将来これらの範囲を広げる場合は、実装より先に PRODUCT tenet を更新する ADR が必要になる。

## Decision

- Dahlia アカウントをアプリ共有の接続として SQLite に登録する。現在の Dahlia Cloud は最大1件、Server は複数登録でき、正規化 origin は一意とする。
- origin は必ず `DahliaCloudConfiguration.make` で検証・正規化した値を保存する。現在の Cloud origin と一致する接続を Cloud、それ以外を Server と
  導出するため、種別は保存しない。
- access token、rotating refresh token、remote account identity と表示情報は接続 UUID ごとの Keychain credential が所有する。SQLite は接続 UUID、
  origin、client ID と作成日時だけを保持する。
- token 利用 API は connection ID を必須とし、refresh の集約と rotation の永続化は接続ごとの service actor が行う。
- sign-out は選択した credential の remote 失効を試みた後、失効結果にかかわらず local credential を削除し、失効失敗は利用者へ通知する。
  これにより ADR-0051 の「失効成功後に削除」という順序を置き換える。接続削除は sign-out 後の明示操作とし、Vault、meeting、録音、文字起こしは削除しない。
- 未リリースの固定 Keychain key は移行せず、起動時に削除する。
- この変更では Vault との関連、sync 設定、meeting schema、sync API、upload を追加しない。sync の実装時に、Vault 側の nullable な connection ID と
  Vault ごとの sync 設定を同じ変更で追加する。新規・既存 Vault は既定で関連なし・sync OFF とする。

## Consequences

- 同じ origin の重複を防ぎながら、現在の Cloud 1件と複数 Server を同時に保持できる。
- credential refresh、rotation、sign-out の影響は接続単位に限定される。
- Keychain credential がない接続は「再サインインが必要」と表示し、ローカル機能を妨げない。
- Vault との 1:N 関係と sync の ON/OFF は sync consumer と一緒に検証・実装し、現時点では効果のない永続状態を持たない。

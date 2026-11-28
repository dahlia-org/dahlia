# デスクトップアプリのバックアップの刷新

対象: macOS アプリ（`apps/macos`）。Private Web、Electron alpha、Desktop v2 にはバックアップがないため対象外。
状態: 段階1〜3を実装・自動検証済み。実際の Google アカウントと Databricks workspace での確認が残る（「未解決・未確認」）。
現在の契約: [Workspace archive backup / restore](../spec/desktop/database-backup.md#保存先)。

## 目的

バックアップをクラウドに置く操作を、アプリ自身がプロバイダーアカウントの storage capability で行う。

今は、作成はアプリ、アップロードは内蔵 Pi の `workspace-backup` skill と Google Drive MCP、一覧とダウンロードはアプリの読み取り専用 Drive client、と3つに分かれている。
利用者はチャットに頼まないとクラウドへ置けず、MCP がローカルファイルのアップロードに対応していないと失敗する。

## 結論（推奨案）

1. `workspace-backup` skill、`dah_create_backup` tool、bridge の `createBackup` を削除する。
2. `ProviderStorage` プロトコルを1つ置き、Google Drive と Databricks Volume の2実装を作る。バックアップはその上の `backup/` を使う。
3. Google Drive は `drive.file` scope で、アプリが作る `Dahlia/backup` フォルダに置く。
4. Databricks は接続ごとに `catalog.schema` を設定し、利用者ごとの managed volume を作って `backup/` に置く。
5. 形式は今の単一 `.tar.gz`（manifest 付き、format 5）を変えない。理由は「形式」の節。
6. 作成・検証・import・復元（`BackupService`、`BackupRestoreStartupProcessor`、`WorkspaceBackupTransfer`）は変えない。変わるのは運ぶ経路だけ。

## 判断が必要な点

レビューで決めてほしい点。推奨を先に書く。

| # | 論点 | 推奨 | 理由 |
| --- | --- | --- | --- |
| 1 | アプリが Drive へ書き込むこと | 認める。現在の契約を書き換える | 現行仕様は「アップロード・フォルダ作成・削除をアプリの Drive client に持たせない」と定める。今回の方針はこれを逆にする。T4 は個別サービス連携を禁じるが、storage などの基本機能のアダプター抽象化は対象外という整理に沿う。要約の Google Docs 書き出しを MCP に任せる規則（2026-11-11）は変えない |
| 2 | Google の scope | `drive.readonly` をやめて `drive.file` にする。既存の `drive.readonly` は再同意のときに引き継がない | `drive.file` はアプリが作ったファイルだけを読み書きできる。Drive 全体を読める今の scope より狭い。代償は判断 3。移行は「Google Drive」の節 |
| 3 | Pi が過去に置いた Drive 上のバックアップ | アプリの一覧に出さない。Drive からダウンロードして「ファイルから読み込む」で復元する | `drive.file` では他のアプリが作ったファイルが見えない。読み込みの経路は今もある |
| 4 | Databricks 経由の Google Drive（`system_ai_agent_google_drive` の proxy） | 削除する | Databricks アカウントの storage は Volume になる。proxy は読み取り専用で、書き込めない |
| 5 | 形式 | 単一 `.tar.gz` のまま | 「形式」の節 |
| 6 | volume 名と再利用の条件 | `user_data_<Databricks の利用者 ID>`。利用者 ID は数字の部分だけを使う。comment にメールアドレス。すでにある volume は、所有者が自分で `MANAGED` のときだけ使う | メールアドレスの前半から作ると、記号の置換（`a.b` と `a_b`）や別ドメインの同じ前半で他人と衝突する。所有者の確認があるので他人の volume には書かないが、後から来た利用者はストレージを使えなくなる。メールアドレスが変わると別の volume になり、以前のバックアップが一覧から消える。ID は変わらず、偶然には衝突しない。ただし他人が同じ名前の volume を先に作って書き込み権限を付けることはできるので、名前だけでは自分のものと言えない |
| 7 | ローカルの世代 | 「この Mac のみ」では保持する。クラウド向けの作成と復元は転送用の世代を使い、利用者に見せず、転送の完了・失敗・中止後に消す | 保存先を選ぶだけで作成・復元できるようにする。失敗時は元のデータから作り直せる。保持済みのローカル世代と上書き前の安全バックアップは残す |
| 8 | 保存先の数 | 1つだけ選ぶ（なし＝ローカルのみ） | 複数へ同時に置く要求はまだない |
| 9 | 暗号化 | 今回は入れない。画面に見える範囲を書く | Volume は schema / catalog の所有者と metastore 管理者が読める。鍵を失うと復元できなくなるため、鍵の管理を決めてから別に扱う |
| 10 | 自動（定期）バックアップ | 今回は入れない | 依頼に含まれない。アプリがアップロードを持てば後から足せる |

## 形式

今の形式はすでに単一のアーカイブである。`manifest.json`（各 entry のサイズと SHA-256、世代 UUID、schema、Workspace 一覧）、`database.sqlite`（選択した Workspace だけを抜き出した DB）、`files/{fileId}/original`（画像の原本）を1つの `.tar.gz` に入れる。

| 案 | 内容 | 良い点 | 悪い点 |
| --- | --- | --- | --- |
| A（推奨） | 世代ごとに自己完結した単一 `.tar.gz`（今のまま） | 1世代＝1ファイルで、アップロードの完了がそのまま公開になる。利用者が Drive から取り出してそのまま読み込める。検証と復元のコードとテストをそのまま使える | 毎回すべての画像を送る。画像が多い Workspace では遅く、容量も世代数に比例する |
| B | DB のアーカイブ＋画像を `files/<fileId>` に1回だけ置く | 2回目から差分だけ送る | 1世代が多数のファイルに分かれる。初回は画像の数だけ要求が出る（Drive は1件ずつで遅い）。世代を消すときに参照のない画像の回収が要る。途中で止まった世代の扱いが要る |
| C | 基準アーカイブ＋差分アーカイブ | 要求の数は少ないまま差分にできる | 復元に連鎖が要り、途中の1つが欠けるとそれ以降を失う。検証と復元を書き直す |

A を推す。B と C の利点は容量と時間だけで、今それが問題だという計測がない。

- 実装前に、実際の Workspace で世代のサイズを測る（下の「未解決」1）。
- 圧縮を強めても小さくならない。画像の原本は保存時に WebP へ変換済みで、gzip でも zstd でもほぼ縮まない。縮むのは DB（文字起こしと要約）だけで、これは今の gzip で済んでいる。世代のサイズはほぼ画像の合計で決まる。
- Databricks は Files API 2.0 の単一 PUT を使う（2026-11-27 にユーザーが決定。一度 3.0 前提としたが同日に 2.0 へ戻した）。1回のアップロードは 5000 MiB まで（[Files API](https://docs.databricks.com/aws/en/volumes/files-api/)、2026-11-27 確認）。これを超える世代は Databricks へのアップロードを断り、対象の Workspace を減らすか別の保存先を選んで作り直すよう案内する。転送用の世代は消す。
- Files API 3.0 のマルチパートアップロード（5000 MiB 超、1パート 5 MiB〜4000 MiB）は使わない。Beta で、workspace 管理者が Previews で有効にする必要があり、接続先が地域のホスト名（`<workspace-id>.storage.<region>.<domain>`）になり、ネットワークの追加要件もある。5000 MiB を超える世代が実際に出たら、`DatabricksVolumeStorage` の `upload` の中だけを 3.0 に替える（形式と他の実装は変わらない）。
- Drive の resumable upload は 5 TB まで置けるので、上限は Databricks だけの問題になる。

## ストレージの抽象化

```swift
/// A provider account's file storage, addressed by a path relative to Dahlia's root there.
protocol ProviderStorage: Sendable {
    func list(directory: String) async throws -> [ProviderStorageFile]
    func upload(_ file: URL, to directory: String, name: String) async throws
    func download(_ file: ProviderStorageFile) async throws -> URL       // 一時ファイル
    func delete(_ file: ProviderStorageFile) async throws
}

struct ProviderStorageFile: Identifiable, Equatable, Sendable {
    let id: String          // 実装が決める不透明な値。Drive は file ID、Databricks は volume 内のパス
    let name: String
    let size: Int64?
    let modifiedAt: Date?
}
```

- ダウンロードと削除は、一覧が返した `ProviderStorageFile` の `id` で対象を決める。名前では決めない。Drive は同じフォルダに同名のファイルを置けるので、名前では対象が1つに決まらない。
- 同じ世代を2回置かない。世代のファイル名は世代 UUID を含み、中身は変わらない。アップロードの前に一覧を取り、同じ名前があれば「アップロード済み」として送らない。この判定は呼び出す側（バックアップ）に1か所だけ置き、2つの実装で共有する。
- それでも同名のファイルが並んだ場合（2台の Mac が同時に同じ世代を置いた場合など）は、一覧にそのまま両方を出す。`id` が別なので、どちらもダウンロードと削除ができる。

- バックアップは `backup/<今のファイル名>` だけを使う。音声は将来 `audio/` を使う（今回は作らない）。
- ルートは実装が決める。Drive は `My Drive/Dahlia`、Databricks は `/Volumes/<catalog>/<schema>/<volume>`。
- `ProviderAccount` に `storage() -> (any ProviderStorage)?` を足し、`.google` と `.databricks` が返す。新しいストレージは case と実装を1つ足せば入る。
- `ProviderAccount.capabilities` の `.databricks` に `.storage` を足す。`AgentProviderRegistrationView` の表示も合わせる。

### Google Drive

- scope を `drive.file` に替える（`GoogleOAuthScope.drive`）。同意画面の説明（`GoogleOAuthDisclosure` の drive）と[プライバシーポリシー](../../apps/site/privacy/index.html)（日英）を書き換える。
- 既存の認可の移行: `GoogleSignInAdapter.authorizationScopesForSignIn` は、要求する scope に、保存済みの session が持つ scope を足して認可を求める（Drive を求めても Calendar を落とさないため）。このままだと `drive.readonly` を持つ既存の利用者は再同意の後も `drive.readonly` を持ち続け、「アプリが作ったファイルだけが見える」が成り立たない。足す前に、保存済みの scope から `drive.readonly` を除く。認可 URL は `include_granted_scopes` を付けていないので、新しい token は要求した scope だけを持つ。
  - Calendar の scope は保存済みの側に残るので、これまでどおり引き継ぐ。Calendar の再接続は要らない。
  - 再同意の前の session は `drive.file` を持たないので、バックアップの画面は「接続」を出す。その間、保存済みの token に残る `drive.readonly` をアプリは使わない（Drive を読むコードが `drive.file` を要求するため）。
  - 古い token の失効（revoke）はしない。Google の revoke は Calendar を含む認可全体を取り消す。
- フォルダは `root` の下の `Dahlia`、その下の `backup` を名前で探し、なければ作る。`drive.file` ではアプリが作ったものしか見えないので、利用者が手で作った同名フォルダとは混ざらない。
- 同名のフォルダが2つ以上見つかったら、どれも選ばずエラーにする（今の `ambiguousFolder` を引き継ぐ）。2台の Mac が同時に初めてフォルダを作ると起こり得る。エラーには Drive で片方へまとめるよう書く。自動で統合しない。
- アップロードは resumable upload の session を開き、`URLSession.upload(for:fromFile:)` で1回で送る。途中で失敗したら最初からやり直す（再開は入れない）。
- `GoogleDriveBackupClient` を `GoogleDriveStorage` に置き換える。file ID の検証は残す。`fetchAccount` は Databricks 経由の Drive の経路でだけ使っていたので消した。
- 削除は完全には消さず、Drive のゴミ箱へ移す（利用者が Drive で戻せる）。
- `DatabricksProxyGoogleSignInProvider` の drive 用の経路（`driveConnectionName`、`.drive` の proxy URL、切断キー）を削除する。Drive は Google のプロバイダーアカウントだけが担う。

### Databricks Volume

- 設定: Databricks プロバイダーアカウント共通の `catalog.schema` として `provider_accounts.settingsJSON` に保存する。「プロバイダー」と「クラウドストレージ」から同じ専用モーダルを開き、既存のカタログ・スキーマを選ぶ。スキーマは新規作成もできる。カラム追加は未リリースの `v67_providerAccounts` に統合し、中間版の設定移行は設けない。接続を削除すると設定も消える。
- volume: 初回の利用時に `GET /api/2.0/preview/scim/v2/Me` で利用者 ID を取り、`POST /api/2.1/unity-catalog/volumes`（`MANAGED`、名前 `user_data_<ID>`）で作る。
- 利用者 ID は数字の部分だけを使う。値が `<user_id>@<account_id>` の形なら `@` の前を取る。取り出した結果が数字だけでなければ、volume を作らずにエラーにする（volume 名に `@` などの記号を入れない）。SCIM `Me` の `id` が数字だけで返るか、`@` 付きで返るかは実 workspace で確かめる（「未解決」2）。
- すでに同じ名前の volume がある場合は、`GET /api/2.1/unity-catalog/volumes/<catalog>.<schema>.<名前>` の `owner` が自分（SCIM `Me` の `userName`）で、`volume_type` が `MANAGED` のときだけ使う。どちらかが違えば、一覧もアップロードもせずに止め、volume 名と所有者を設定画面に出す。確認は保存先を選んで最初に使うときに1回行う（設定画面を開き直すとやり直す）。
- ファイル: Files API 2.0（workspace の URL の `/api/2.0/fs/files/Volumes/...` の PUT / GET / DELETE、`/api/2.0/fs/directories/...` の一覧）。アップロードは `URLSession.upload(for:fromFile:)` で1回で送る。token は既存の `DatabricksOAuthService`（scope `all-apis`）で足りる。
- 必要な権限: 初回の作成に `USE CATALOG`、`USE SCHEMA`、`CREATE VOLUME`。2回目からは `USE CATALOG` と `USE SCHEMA` だけで足りる（volume の所有者は `READ VOLUME` と `WRITE VOLUME` を含む全権限を持つ）。所有者でなければ上の条件で止まるので、`READ VOLUME` / `WRITE VOLUME` だけを付与された volume は使わない。足りないときは、どの権限が要るかを設定画面に出す。
- 未設定の接続は保存先の候補に「設定が必要」と出し、「プロバイダー」ページへ案内する。

## 画面（設定 → データ保護 → バックアップ）

- 保存先のピッカー: 「この Mac のみ」と、storage を持つプロバイダーアカウント。今の Drive のピッカーはカレンダーの経路（`GoogleCalendarProvider`）を共有しているので、専用の設定 `backupStorageAccount`（接続 UUID）に分ける。
- 「バックアップを作成」: 「この Mac のみ」なら世代を保持する。クラウドなら転送用の世代を作ってアップロードし、成否にかかわらず消す。失敗時は理由を表示する。
- ローカルの世代の行: 「この Mac のみ」で復元・書き出し・削除を表示する。クラウド選択中はローカルの世代を表示しない。
- 保存先の一覧: 復元と削除（確認ダイアログ付き）を表示する。復元はダウンロードと import 検証を透過的に行い、直接復元画面を開く。転送用の世代はステージング後、復元中止時、画面終了時に消す。
- 進行中はスピナーと中止。アップロードは MainActor の外で行い、録音と保存を待たせない。
- 自動で世代を減らさない点は今のまま。

## 削除するもの

- `AgentSkills/workspace-backup/`、`PiBundle.presetSkillNames` の該当項目（preset は bundle から読むので、利用者の環境に残骸は出ない）。
- `PiExtension/dahlia.ts` の `dah_create_backup`、`PiChatService` の tool 一覧と `createBackup`、`PiRuntimeService` の bridge 名。
- `GoogleDriveBackupModel`（保存先に依らないモデルに置き換える）、Drive の proxy 経路、対応する L10n のキー（日英）とテスト。

## 対象の面

| 面 | 扱い |
| --- | --- |
| クライアント | macOS アプリだけ。他のクライアントにバックアップはない |
| アカウント | アプリのアカウントの Google と Databricks のプロバイダーアカウント。Dahlia アカウントは storage を持たない |
| 入口 | 設定 → データ保護 → バックアップ、設定 → プロバイダー（Databricks の catalog.schema）。メニューとショートカットにバックアップの入口は今もない |
| AI | チャットからのバックアップ作成をなくす。Local MCP（`dahlia-mcp`）は読み取り専用のままで、バックアップの tool は足さない |
| 戻る経路 | 保存先を「この Mac のみ」に戻せる。アップロードは中止できる。リモートの世代は削除できる。Google の同意は「プロバイダー」で取り消せる |

## 段階

各段階は単独で出せる。

1. **抽象化と Google Drive**: `ProviderStorage`、`GoogleDriveStorage`、scope の変更と同意文言、設定画面の保存先・アップロード・一覧・削除、Drive の proxy 経路の削除。
2. **Databricks Volume**: 接続の `catalog.schema` 設定、volume の作成、`DatabricksVolumeStorage`、capability の表示。
3. **skill と tool の削除、仕様の書き換え**: [database-backup.md](../spec/desktop/database-backup.md) の「Google Drive と内蔵 Pi」を「保存先」に書き直し、未確定事項（app が Drive の token を持つか）を消す。[accounts.md](../spec/desktop/accounts.md) の capability の記述、[ai-skills-and-context.md](../spec/desktop/ai-skills-and-context.md) と [pi-runtime.md](../spec/desktop/pi-runtime.md) の skill / tool の記述、README を合わせる。

段階 3 を先に出すと、クラウドへ置く手段がない期間ができる。1 の後に出す。

## 検証

- `ProviderStorage` の2実装: `URLProtocol` の stub で、一覧のページ送り、フォルダと volume の「ない→作る／ある→使う」、アップロード、ダウンロード、削除、HTTP エラーを確認する（今の `GoogleDriveBackupClientTests` を置き換える）。
- Google の scope の移行: 保存済みが Calendar と `drive.readonly` の session から `drive.file` を求めると、認可 URL の scope が Calendar と `drive.file` で、`drive.readonly` を含まないこと。
- Drive: 同名フォルダが2つでエラーになること。同名ファイルが2つ並ぶ一覧で、ダウンロードと削除が選んだ行の file ID だけに届くこと。
- Databricks: 既存 volume の所有者が他人、または `EXTERNAL` のとき、Files API を1回も呼ばずに止まること。
- 同じ名前が保存先にあるとき、アップロードを送らないこと（2実装で共通）。
- 設定のモデル: クラウド作成の転送用世代を成否にかかわらず消すこと、開始時の保存先で保持の扱いを固定すること、保存先の切り替えで古い一覧・復元の結果を捨てること、復元画面の終了後に転送用世代を残さないこと。
- 既存の `BackupServiceTests`、`BackupArchiveTests`、`WorkspaceBackupTests`、`MultiWorkspaceBackupTests`、`BackupRestoreStartupProcessorTests` は変更なしで通ること（形式を変えていない証拠）。
- `test-pi-extension.py` と `PiChatServiceTests` から `dah_create_backup` を外す。
- 実機（`./scripts/run-dev.sh`）: 実際の Google アカウントと Databricks workspace で、作成→アップロード→別の世代としてダウンロード→復元を1回ずつ通す。

## 完了条件

- 設定画面だけで、Google Drive と Databricks Volume のどちらにも、作成・アップロード・一覧・ダウンロード・復元・削除ができる。
- チャットと skill にバックアップの経路が残っていない。
- 仕様、L10n（日英）、プライバシーポリシーが実装と一致している。

## 未解決・未確認

1. 実際の Workspace の世代サイズを測っていない。形式の判断（A か B か）はこの数字に依る。
2. `all-apis` の token で volume の作成と Files API 2.0 が通ること、SCIM `Me` の ID の形式は、実 workspace で確認していない。Files API の上限は文書で確認しただけで、実際には試していない。段階 2 の最初に実 workspace で確かめる。
3. `drive.file` で、別の Mac や再インストール後に同じ Google アカウントで以前の `Dahlia/backup` が見えること（同じ OAuth client が作ったファイルは見える想定）を実機で確認していない。
4. Google の OAuth 同意画面の審査に scope の変更の再申請が要るかは、Google Cloud の設定を見ていないので分からない。
5. Unity Catalog の volume の応答の `owner` が SCIM `Me` の `userName` と同じ形（メールアドレス）で返ることは、実 workspace で確認していない。所有者がグループや service principal に移された volume は、この条件では使えない。
6. Databricks の接続を削除して同じ workspace に再サインインした場合、接続 UUID が変わるので `catalog.schema` を入れ直すことになる。volume 名は利用者 ID 由来なので同じ volume に戻る。

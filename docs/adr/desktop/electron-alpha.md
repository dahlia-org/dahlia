# Electron アルファ版

対象: Desktop（Electron）・共通 UI。採択: 2026-10-03。ユーザー依頼に基づく開発用アルファ。採択は正式版の保存保証や配布を意味しない。

## 決定

`apps/desktop`（`@dahlia-ai/desktop`）は `@dahlia-ai/ui` の同じソースから renderer をビルドし、オンライン接続を前提に Dahlia Server の既存アカウントセッションで動く。Swift 版（`apps/macos`）とは独立したアプリ識別子 `com.dahlia.electron-alpha`、名称 Dahlia Alpha、`~/Library/Application Support/Dahlia Alpha` を使い、DB・設定・Keychain を共有しない。

- renderer は `app://dahlia` から配信し、`/api/**` は main process が Server へ中継する。UI は Web と同じ同一 origin の API 呼び出しを保ち、API の接続先は main process の `DAHLIA_SERVER_URL`（Server の `DAHLIA_APP_URL`、https またはローカルの http）が決める。Server に CORS、header 信頼、bearer 互換の追加は行わない。
- 共通 UI の `/api/v1/session`、Organization 管理などは browser session を前提とするため、認証は既存の browser session と Server 自身の `/sign-in` を使う。Cookie は中継とサインイン窓だけが使う `persist:server` session に保持し、renderer とサインイン中の外部ページから隔離する。
- Web との差分は `App` の小さな props に限る: 共有リンクの origin（`publicOrigin`）、サインイン開始（`signIn`）、サインアウト後の遷移先（`signOutPath`）、Server での AI 実行可否（`serverAI`）。`serverAI={false}` は既存の `ai` capability を落とし、Server の要約ジョブ・要約設定を表示しない。Desktop の AI 実行を Server ジョブで代替しない。
- 保存保証は Web と同じメモリ上の未送信編集とし、閉じる・再読み込み時は確認する。オフライン保存を保存済みとして扱わない。

## 理由と制約

Server ページを BrowserWindow で開くだけでは共通 UI の境界を検証できないため、共通ソースからビルドした renderer を使う。OpenAPI 生成クライアント・live-data・Documents コアをそのまま使い、別の通信基盤や同期処理を作らない。macOS の OAuth（loopback と bearer）は session 専用 API に届かないため、今回は使わない。

Google は埋め込みブラウザでのサインインを拒否する場合がある。正式版ではシステムブラウザからのセッション受け渡し、Desktop 推論、ローカル保存と同期、署名・公証・自動更新を別途決める。録音・文字起こし・メニューバー・会議参加・既存データ移行は対象外。

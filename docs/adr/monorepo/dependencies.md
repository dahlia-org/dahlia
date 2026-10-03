# pnpm workspace と共通 UI の依存管理

対象: Monorepo。採択: 2026-10-03（2026-08-29 のアプリ単位の依存管理を置き換える）。

## 決定

TypeScript は root の pnpm workspace（`apps/server`、`apps/desktop`、`packages/ui`）で管理する。pnpm version、lockfile、依存の build allowlist と override は root の `package.json`・`pnpm-lock.yaml`・`pnpm-workspace.yaml` が所有する。root の `build` と `check` は Turborepo（`turbo.json`）で各 package の同名 script を実行する。`build` は `dist/**` を cache し、依存先 package のソース変更でも cache を無効にするため transit task に依存させる。`check` は検証結果を再生しないよう cache しない。既存 script の環境変数を変えないよう `envMode: loose` とし、外部送信を避けるため root script で Turborepo の telemetry を無効にする。各 package は自身の依存を宣言し、版の追加・更新はユーザー承認を要する。macOS は SwiftPM を維持し、`apps/site` は workspace に含めない。

`@dahlia-ai/ui`（`packages/ui`、非公開）は browser で実行するコードの正本とする。汎用 UI 部品（`components`）、レイアウト（`layout`）、スタイルと utility（`styles.css`、`lib`）、Dahlia 固有の画面（`screens`）、起動とルーティング（`App.tsx`、`app`）、OpenAPI 生成クライアントと live-data・SSE・transaction 処理（`api`）、Documents の runtime 非依存コアとエディタ（`documents`）、Server と共用する browser-safe な wire model（`model`: TypeID、Object URL、Appearance、生成設定、Gateway の model 一覧など）を同じ package 内で分ける。必要性が生じるまで package を追加分割しない。

依存方向は Server → UI、Desktop（Electron）→ UI の一方向とする。UI は Server・Desktop の実行部分、DB、秘密情報、Node 専用モジュールを import しない。Server は UI を `workspace:*` の devDependency として SPA、`./client` library、runtime と型宣言へ同梱し、公開 package に UI への依存を残さない。`@dahlia-ai/server/client` は UI の明示した公開 export を互換のまま再 export する。

## 契約と生成物

Server の wire 契約は引き続き `apps/server/src/api/contracts.ts`（`@hono/zod-openapi`）が所有する。`pnpm openapi:generate`（`apps/server`）は OpenAPI と監査台帳を生成し、Web 用の `openapi-typescript` 型と `openapi-fetch` 呼び出しを `packages/ui/src/api` へ書き出す。Desktop（Swift）は従来どおり `swift-openapi-generator` を使う。UI は生成型を使い、Server の内部型や手書き DTO を正本にしない。OpenAPI 外の委譲プロトコル（`/api/v1/models`）の wire 型だけを `model` に置く。

Documents の Desktop 同梱資材は `packages/ui` の pinned Yjs / Tiptap / ProseMirror 依存から既存 tsup で生成する。`pnpm --filter @dahlia-ai/ui documents:build` で更新し、`documents:check`（UI の `check` に含む）で生成物と同梱ライセンスの再現性を検査する。

## 検証と配置

- UI: `pnpm --filter @dahlia-ai/ui check`（Documents 資材、lint、型、UI テスト）。Server: `apps/server` の `pnpm check`（OpenAPI、lint、型、Server テスト、package、Worker dry-run）。root の `pnpm check` は全 package を順に実行する。
- CI は root の lockfile をキャッシュし、Server 系の job は `--filter @dahlia-ai/server...` で Server と UI だけを install する。
- Databricks Apps の Server は repository root を source とし、DAB の `sync.paths` で root manifest、lockfile、`turbo.json`、`apps/server`、`packages/ui`（と Hindsight、setup notebook）だけを upload する。Apps はそこで `pnpm install --frozen-lockfile` と root の `pnpm run build` を実行し、`corepack pnpm --filter @dahlia-ai/server start:databricks` で起動する。`pnpm test:package` は同じ Server workspace のファイルを一時 directory へ写して install・build し、pack した artifact を workspace 外で検証する。
- Electron alpha（[`apps/desktop`](../desktop/electron-alpha.md)）は `electron` 44.4.5 を固定し、バイナリは初回起動時に取得する（`allowBuilds: electron: false`）。CI は Server と別の `electron-ci.yml` で lint・型・テスト・build を実行する。Databricks の staging と Server の container には含めない。
- Container は repository root を context とし（`docker build -f apps/server/Dockerfile .`）、`pnpm deploy --prod` の出力だけを runtime image に入れる。

## 変更の経緯

2026-08-29 は共有 TypeScript package がないため root workspace を廃止し、Server がアプリ単位で manifest・lockfile を所有した。2026-09-29 の [Documents ADR](../shared/documents.md) も同じ前提で Documents コアを `apps/server` に置いた。Web と Electron が同じ UI ソースを使う必要が生じたため、共有 package を `packages/ui` に切り出し、root workspace を再導入した。Electron の追加は、依頼で承認された範囲の依存追加（`electron` と同版の既存ツール）である。Turborepo（`turbo` 2.11.4、root の devDependency）も依頼により追加した。lockfile には `turbo` とその platform binary だけを追加し、既存依存の解決は変えていない。

移行時、registry proxy が `typescript-eslint@8.66.1-alpha.4` を提供しなくなっていたため、新しい importer では同版を解決できず、workspace 全体で `8.70.1` に揃った（dev 依存のみ）。他の依存版は既存 lockfile のまま維持した。

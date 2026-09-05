# Local MCP と Project 階層

対象: Desktop・local MCP。採択: 2026-07。詳細な操作は [Project workspaces](../../project-workspaces.md)。

## Vault 境界

署名済み stdio helper `dahlia-mcp` は起動時の `--vault-id <UUID>` に固定し、名前を認可に使わない。全 query を Vault で制約し、別 Vault の ID は not found。cursor にも Vault、meeting、ordering identity を含めて検証する。

既定は SQLite read-only、明示 `--write` だけが公開 write tool を有効にする。helper は migration や permission 変更をせず、初期化時の schema 検証でアプリ更新後の初回起動を必要とする。

発見は compact metadata と [summary 本文の検索](search.md)、詳細は保存済み summary、原文 transcript のページング、縮小 screenshot を返す。音声、note、翻訳、未確定 transcript と transcript 全文検索は対象外。summary schema v3 の description と meeting metadata の更新は [サマリー](summary.md) に従う。

chat の workspace / 履歴は Vault UUID で隔離する。Vault 切替は新しい floating session とし、別 Vault に紐づく detached session はその Vault が active になるまで送信不可。start / resume とも user MCP を無効にして Dahlia helper を使い、要約は全 MCP を無効にする。設定画面は登録 command の表示・copy だけで外部 client 設定を書き換えない。外部 client の同名登録を別 Vault へ変えるには明示的な再登録が必要。

## Project の正本

`projects.id` を安定 identity、parent ID + name を階層の正本とする。path は読込・操作計画時に導出し、別の正準 path を保存しない。採択時の nameKey は Unicode 正規化・case fold による sibling uniqueness を app / migration / MCP の共通処理で強制する契約とした。

root + 1 subproject の2段階に限定し、parent は同一 Vault の root、子は children を持てない。root だけが明示 projectType を持ち、子は継承する。revision、Vault 所有の不変性、同一 Vault meeting membership を DB と各 writer で検証する。直接 SQL は supported mutation interface ではない。

## Export directory

directory は派生 Summary 出力先。Project 作成では作らず、rename / reparent で旧 derived path に沿う tracked Summary だけを移し、必要な directory を遅延作成する。無関係な file や directory 全体は動かさない。filesystem event は tracked export path を保守できるが、Project の作成・同定・rename・reparent・削除をしない。

file と DB の変更は shared Vault lock、完全な事前検証、単一 DB transaction、失敗時の file compensation を使う。[summary 訂正](summary.md#訂正と-export) も同じ境界を共有する。

## 経緯と制約

slash-delimited path identity、親 ID と path の二重正本、Finder との双方向階層同期は、rename の fan-out と offline の曖昧性を増やすため却下した。任意階層と子への type 複製も製品に必要な範囲を超える。

旧 path migration は UUID、description、日時、membership を保ち、深い階層を元 root の直下へ平坦化し、名前衝突を決定的 suffix で解消した。既存 Summary は動かさず legacy path を保持し、旧 directory-sync / context column と CONTEXT.md 依存を廃止した。

local MCP の Project delete / merge は復旧契約を決めるまで公開しない。Server の domain transaction による削除は [同期契約](../shared/sync.md) の別経路として扱う。

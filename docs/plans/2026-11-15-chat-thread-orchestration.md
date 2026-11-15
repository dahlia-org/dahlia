# チャットのスレッド管理

対象: macOS の内蔵 Pi チャット。Local Account / Server Account 共通。
状態: 実装・自動検証完了。2026-11-15、同じアカウント内を操作対象とする方針をユーザー承認済み。
署名済みアプリの手動操作確認は未実施。

この計画の設計判断と操作境界は[スレッド管理 ADR](../adr/desktop/chat-thread-orchestration.md)へ集約した。
実行の所有・保存・表示の現在の契約は [Architecture](../../ARCHITECTURE.md#bounded-and-replaceable-projections) と
[内蔵 Pi runtime](../adr/desktop/pi-runtime.md) を参照する。完了した実装手順は再利用しない。

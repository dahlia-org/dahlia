# Plans

ここは進行中の実装計画の入口であり、現行仕様の正本ではない。現在の契約は [Spec index](../spec/README.md) を参照する。

## 進行中の計画

| 計画 | 状態 |
| --- | --- |
| [Pi の自己学習（メモリー・スキル改善・定期実行）](2026-11-15-pi-self-learning.md) | 実装・自動検証済み。現在の契約は[自己学習](../spec/desktop/pi-self-learning.md)・[定期実行](../spec/desktop/scheduled-agent-scope.md)。実モデルの30会話評価・費用計測と実アプリの手動操作確認が残る |
| [Desktop v2（Electron、独立実装）](2026-11-20-desktop-v2.md) | 推奨案で実装・自動検証済み。実 Workspace での要約と実機でのシステム音声録音は未確認。Tenet の例外はユーザー確認待ち |
| [ドキュメント管理方針の見直し](2026-11-20-documentation-management.md) | 試行と一括移行を実施。ユーザーのレビュー待ち |
| [macOS アプリの応答性：構成の作り直し](2026-11-20-macos-responsiveness-rearchitecture.md) | 実装と自動検証は完了。ライブ字幕とライブ文字起こしの実機計測（録音が必要）が残る |
| [単一アカウントへの移行とプロバイダーアカウント](2026-11-23-single-account-provider-accounts.md) | 段階 1〜4 を実装済み。実アプリでの確認、`dahlia-mcp --account` の削除、旧ディレクトリと旧設定キーの削除（1 リリース後）が残る |

## 計画の扱い

新しい計画は対象、状態、完了条件、未解決事項を明記する。完了したら、現在の契約・未解決事項・未検証の事項を `docs/spec/` の該当する仕様へ移し、計画は削除する。削除した計画とレビュー記録の原文は git の履歴で辿れる。

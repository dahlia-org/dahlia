import Foundation

/// 要約生成の各ステップの進捗状態を管理する。
@MainActor @Observable
final class SummaryProgressState {
    enum StepStatus {
        case pending
        case running
        case completed
        case skipped
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .completed, .skipped, .failed: true
            default: false
            }
        }

        var isSkipped: Bool {
            if case .skipped = self {
                true
            } else {
                false
            }
        }

        var isFailed: Bool {
            if case .failed = self {
                true
            } else {
                false
            }
        }

        var failureMessage: String? {
            if case let .failed(message) = self {
                message
            } else {
                nil
            }
        }

        var accessibilityDescription: String {
            switch self {
            case .pending: L10n.waiting
            case .running: L10n.inProgress
            case .completed: L10n.completed
            case .skipped: L10n.skipped
            case let .failed(message): message
            }
        }
    }

    var vaultExport: StepStatus = .pending
    var googleDocsExport: StepStatus = .pending
    var summaryGeneration: StepStatus = .pending
    var transcription: StepStatus = .skipped
    var transcriptionProgress: Double?

    /// 全ステップが完了・失敗・スキップのいずれかに到達したか。
    var isAllDone: Bool {
        vaultExport.isTerminal
            && googleDocsExport.isTerminal
            && summaryGeneration.isTerminal
            && transcription.isTerminal
    }

}

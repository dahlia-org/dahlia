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

    var isVisible = false
    var vaultExport: StepStatus = .pending
    var googleDocsExport: StepStatus = .pending
    var summaryGeneration: StepStatus = .pending
    private var presentationID: UUID?

    /// 全ステップが完了またはスキップ済みか。
    var isAllDone: Bool {
        vaultExport.isTerminal
            && googleDocsExport.isTerminal
            && summaryGeneration.isTerminal
    }

    func reset() {
        vaultExport = .pending
        googleDocsExport = .pending
        summaryGeneration = .pending
    }

    @discardableResult
    func show() -> UUID {
        let presentationID = UUID()
        reset()
        self.presentationID = presentationID
        isVisible = true
        return presentationID
    }

    func dismiss() {
        presentationID = nil
        isVisible = false
    }

    func dismiss(ifCurrent presentationID: UUID) {
        guard self.presentationID == presentationID else { return }
        dismiss()
    }
}

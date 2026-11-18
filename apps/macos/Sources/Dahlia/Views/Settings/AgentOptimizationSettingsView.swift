import SwiftUI

/// Unattended upkeep of the account's agent: memory reviews and the history of every system run.
/// Skill organization lives in Settings → Skills.
struct AgentOptimizationSettingsView: View {
    let account: CodexRuntimeProvider
    @State private var model: AgentOptimizationSettingsModel
    @AppStorage private var memoryReview: Bool
    @AppStorage private var memoryEnabled: Bool

    init(account: CodexRuntimeProvider) {
        self.account = account
        let key = account.accountKey
        _model = State(initialValue: AgentOptimizationSettingsModel(account: account))
        // Starts from the single review switch that skill and memory organization replaced.
        _memoryReview = AppStorage(wrappedValue: AgentLearningSettings.legacyReviewEnabled(key), AgentLearningSettings.memoryReviewKey(key))
        _memoryEnabled = AppStorage(wrappedValue: true, AgentLearningSettings.memoryKey(key))
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.agentMemoryReviewEnabled, isOn: $memoryReview).disabled(!memoryEnabled)
                Text(L10n.agentMemoryReviewHelp).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(L10n.agentSystemRuns) { EmptyView() }
                if model.runs.isEmpty {
                    Text(L10n.agentSystemRunsEmpty).foregroundStyle(.secondary)
                }
                ForEach(model.runs) { run in
                    AgentSystemRunRow(run: run)
                }
                if model.hasMoreRuns {
                    Button(L10n.agentSystemRunsMore) { Task { await model.loadMore() } }
                        .buttonStyle(.dahlia())
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped).toggleStyle(.switch)
        .font(.dahliaBody)
        .disabled(model.isBusy)
        .task { await model.refresh() }
        .onChange(of: memoryReview) { Task { await PiChatService.shared.drainLearningWork() } }
    }
}

private struct AgentSystemRunRow: View {
    let run: AgentSystemRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.task == "curator" ? L10n.agentSystemTaskCurator : L10n.agentSystemTaskReview).font(.dahliaHeadline)
                Spacer()
                Text(status).foregroundStyle(run.status == "failed" ? .red : .secondary)
                Text(run.startedAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
            }
            .font(.dahliaSecondary)
            if !run.summary.isEmpty { Text(run.summary).textSelection(.enabled) }
            if !run.report.isEmpty {
                DisclosureGroup(L10n.agentSystemRunsReport) {
                    Text(run.report).font(.dahliaSecondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var status: String {
        switch run.status {
        case "completed": L10n.agentSystemRunCompleted
        case "failed": L10n.agentSystemRunFailed
        case "cancelled": L10n.agentSystemRunCancelled
        case "seeded": L10n.agentSystemRunSeeded
        case "running": L10n.agentSystemRunRunning
        default: L10n.agentSystemRunInterrupted
        }
    }
}

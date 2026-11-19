import SwiftUI

/// Evolving one skill with GEPA (hermes-agent-self-evolution), in Settings → Skills → Auto optimization. The run itself happens
/// in a new chat, where the user follows it and can ask for more.
struct SkillOptimizerSection: View {
    let model: AgentOptimizationSettingsModel
    @State private var skill = ""

    var body: some View {
        Section {
            LabeledContent {
                Picker(L10n.agentOptimizerSkill, selection: $skill) {
                    if model.optimizableSkills.isEmpty { Text(L10n.agentOptimizerNoSkills).font(.dahliaBody).tag("") }
                    ForEach(model.optimizableSkills, id: \.self) { Text($0).font(.dahliaBody).tag($0) }
                }
                .labelsHidden()
            } label: {
                HStack {
                    Text(L10n.agentOptimizerSkill)
                    SettingsInfoButton(help: L10n.agentOptimizerHelp)
                }
            }
            Button(L10n.agentOptimizerStart) {
                NotificationCenter.default.post(name: AgentLearningSettings.sendChat, object: L10n.agentOptimizerPrompt(skill))
            }
            .buttonStyle(.dahlia())
            .disabled(!model.optimizableSkills.contains(skill))
            AgentSystemRunRows(model: model, task: "optimizer", title: L10n.agentOptimizerRuns)
        } header: {
            AgentSectionHeader(title: L10n.agentSkillOptimizer) { EmptyView() }
        }
        .onChange(of: model.optimizableSkills, initial: true) {
            if !model.optimizableSkills.contains(skill) { skill = model.optimizableSkills.first ?? "" }
        }
    }
}

/// The rows of one system task's runs (`review`, `curator` or `optimizer`) inside its section, shown once it has any.
struct AgentSystemRunRows: View {
    let model: AgentOptimizationSettingsModel
    let task: String
    let title: String

    var body: some View {
        if let runs = model.runs[task], !runs.isEmpty {
            LabeledContent(title) { EmptyView() }
            ForEach(runs) { run in
                AgentSystemRunRow(run: run)
            }
            if model.hasMoreRuns.contains(task) {
                Button(L10n.agentSystemRunsMore) { Task { await model.loadMore(task) } }
                    .buttonStyle(.dahlia())
            }
        }
    }
}

private struct AgentSystemRunRow: View {
    let run: AgentSystemRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.dahliaHeadline)
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

    private var title: String {
        switch run.task {
        case "curator": L10n.agentSystemTaskCurator
        case "optimizer": L10n.agentSkillOptimizer
        default: L10n.agentSystemTaskReview
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

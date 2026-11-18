import SwiftUI

/// Settings → Skills for the open account: the skill library and its automatic organization (Hermes Curator).
struct SkillSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case manage
        case readOnly
        case curation

        var id: Self { self }

        var label: String {
            switch self {
            case .manage: L10n.skillsTabManage
            case .readOnly: L10n.skillsTabReadOnly
            case .curation: L10n.skillsTabCuration
            }
        }
    }

    @State private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var tab = Tab.manage

    var body: some View {
        let account = CodexRuntimeProvider(
            accountConnectionID: workspaceSettings.accountConnectionID,
            databricksConnectionID: workspaceSettings.databricksAccountConnectionID
        )
        VStack(spacing: 0) {
            // In a grouped form's header, the tabs share the column of the settings title and the sections below.
            Form {
                Section {
                    EmptyView()
                } header: {
                    UnderlineTabBar(tabs: Tab.allCases, selection: $tab, label: \.label, accessibilityLabel: L10n.agentSkills)
                }
            }
            .formStyle(.grouped)
            .font(.dahliaBody)
            .fixedSize(horizontal: false, vertical: true)

            switch tab {
            case .manage: AgentSkillSettingsView(account: account)
            case .readOnly: AgentSkillSettingsView(account: account, readOnly: true)
            case .curation: SkillCurationSettingsView(account: account)
            }
        }
        .id(account)
    }
}

/// Hermes Curator settings, skill reviews, and the archived skills.
private struct SkillCurationSettingsView: View {
    let account: CodexRuntimeProvider
    @State private var model: AgentOptimizationSettingsModel
    @State private var models: [CodexModel] = []
    @AppStorage private var consolidationModel: String
    @AppStorage private var consolidationEffort: String
    @AppStorage private var curatorEnabled: Bool
    @AppStorage private var interval: Int
    @AppStorage private var archiveAfter: Int
    @AppStorage private var consolidate: Bool
    @AppStorage private var skillReview: Bool

    init(account: CodexRuntimeProvider) {
        self.account = account
        let key = account.accountKey
        _model = State(initialValue: AgentOptimizationSettingsModel(account: account))
        _consolidationModel = AppStorage(wrappedValue: "", SkillCuratorSettings.modelKey(key))
        _consolidationEffort = AppStorage(wrappedValue: "", SkillCuratorSettings.effortKey(key))
        _curatorEnabled = AppStorage(wrappedValue: true, SkillCuratorSettings.enabledKey(key))
        _interval = AppStorage(wrappedValue: SkillCuratorSettings.intervalHours(key), SkillCuratorSettings.intervalKey(key))
        _archiveAfter = AppStorage(wrappedValue: SkillCuratorSettings.archiveAfterDays(key), SkillCuratorSettings.archiveKey(key))
        _consolidate = AppStorage(wrappedValue: false, SkillCuratorSettings.consolidateKey(key))
        // Starts from the single review switch that skill and memory organization replaced.
        _skillReview = AppStorage(wrappedValue: AgentLearningSettings.legacyReviewEnabled(key), AgentLearningSettings.skillReviewKey(key))
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.agentSkillCurator, isOn: $curatorEnabled)
                Picker(L10n.agentCuratorInterval, selection: $interval) {
                    ForEach(SkillCuratorSettings.intervalChoices, id: \.self) { hours in
                        Text(L10n.agentCuratorIntervalDays(hours / 24)).font(.dahliaBody).tag(hours)
                    }
                }
                .disabled(!curatorEnabled)
                Picker(L10n.agentCuratorArchiveAfter, selection: $archiveAfter) {
                    ForEach(SkillCuratorSettings.archiveChoices, id: \.self) { days in
                        Text(L10n.agentCuratorDays(days)).font(.dahliaBody).tag(days)
                    }
                }
                .disabled(!curatorEnabled)
                Text(L10n.agentSkillCuratorHelp).foregroundStyle(.secondary)
                Toggle(L10n.agentCuratorConsolidate, isOn: $consolidate).disabled(!curatorEnabled)
                Text(L10n.agentCuratorConsolidateHelp).foregroundStyle(.secondary)
                LabeledContent {
                    Picker(L10n.agentCuratorModel, selection: $consolidationModel) {
                        Text(L10n.agentCuratorModelAuto).font(.dahliaBody).tag("")
                        if !consolidationModel.isEmpty, !models.contains(where: { $0.model == consolidationModel }) {
                            Text(consolidationModel).font(.dahliaBody).tag(consolidationModel)
                        }
                        ForEach(models) { model in
                            Text(model.displayName).font(.dahliaBody).tag(model.model)
                        }
                    }
                    .labelsHidden()
                } label: {
                    HStack {
                        Text(L10n.agentCuratorModel)
                        SettingsInfoButton(help: L10n.agentCuratorModelHelp)
                    }
                }
                .disabled(!curatorEnabled || !consolidate)
                LabeledContent {
                    Picker(L10n.agentCuratorEffort, selection: $consolidationEffort) {
                        Text(L10n.agentCuratorEffortDefault).font(.dahliaBody).tag("")
                        ForEach(efforts) { option in
                            Text(option.displayName).font(.dahliaBody).tag(option.reasoningEffort)
                        }
                    }
                    .labelsHidden()
                } label: {
                    HStack {
                        Text(L10n.agentCuratorEffort)
                        SettingsInfoButton(help: L10n.agentCuratorEffortHelp)
                    }
                }
                .disabled(!curatorEnabled || !consolidate)
            }
            Section {
                Toggle(L10n.agentSkillReviewEnabled, isOn: $skillReview)
            }
            if !model.archived.isEmpty {
                Section {
                    LabeledContent(L10n.agentArchivedSkills) { EmptyView() }
                    ForEach(model.archived, id: \.self) { name in
                        LabeledContent(name) {
                            Button(L10n.agentSkillRestore) { Task { await model.restore(name) } }
                                .buttonStyle(.dahlia())
                        }
                    }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped).toggleStyle(.switch)
        .font(.dahliaBody)
        .disabled(model.isBusy)
        .task {
            await model.refresh()
            models = await (try? PiRuntimeService.shared.models(for: account, forceRefresh: false))?.filter { !$0.hidden } ?? []
        }
        .onChange(of: skillReview) { Task { await PiChatService.shared.drainLearningWork() } }
        .onChange(of: curatorEnabled) { Task { await PiChatService.shared.drainLearningWork() } }
        .onChange(of: consolidate) { Task { await PiChatService.shared.drainLearningWork() } }
    }

    /// The selected model's levels; with the automatic model, every level a listed model offers.
    private var efforts: [CodexReasoningEffortOption] {
        let options = models.first(where: { $0.model == consolidationModel })?.supportedReasoningEfforts
            ?? models.flatMap(\.supportedReasoningEfforts)
        var seen: Set<String> = []
        let unique = options.filter { seen.insert($0.reasoningEffort).inserted }
        return unique.contains(where: { $0.reasoningEffort == consolidationEffort }) || consolidationEffort.isEmpty
            ? unique : unique + [CodexReasoningEffortOption(reasoningEffort: consolidationEffort, description: "")]
    }
}

import SwiftUI

/// Settings → Skills for the open account: the skill library, and its automatic organization (Hermes Curator) and
/// optimization (hermes-agent-self-evolution) with the history of unattended runs.
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
            accountConnectionID: workspaceSettings.accountConnectionID
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

/// Skill updates from conversations, the Hermes Curator with its archived skills, and skill optimization, each with its runs.
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
    @AppStorage private var skillInterval: Int

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
        _skillInterval = AppStorage(wrappedValue: AgentLearningSettings.skillInterval(key), AgentLearningSettings.skillIntervalKey(key))
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.agentSkillReviewEnabled, isOn: $skillReview)
                Group {
                    Picker(L10n.agentReviewInterval, selection: $skillInterval) {
                        ForEach(AgentLearningSettings.reviewIntervalChoices, id: \.self) { count in
                            Text(L10n.agentSkillReviewEvery(count)).font(.dahliaBody).tag(count)
                        }
                    }
                    AgentReviewModelRows(account: account, kind: .skill, models: models)
                }
                .disabled(!skillReview)
                AgentSystemRunRows(model: model, task: "skillReview", title: L10n.agentReviewRuns)
            } header: {
                AgentSectionHeader(title: L10n.agentSkillReviewSection) { EmptyView() }
            }
            Section {
                SettingsInfoToggle(title: L10n.agentCuratorEnabled, help: L10n.agentSkillCuratorHelp, isOn: $curatorEnabled)
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
                SettingsInfoToggle(title: L10n.agentCuratorConsolidate, help: L10n.agentCuratorConsolidateHelp, isOn: $consolidate)
                    .disabled(!curatorEnabled)
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
                        ForEach(models.reasoningEfforts(for: consolidationModel, keeping: consolidationEffort)) { option in
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
                AgentSystemRunRows(model: model, task: "curator", title: L10n.agentCuratorRuns)
                if !model.archived.isEmpty {
                    LabeledContent(L10n.agentArchivedSkills) { EmptyView() }
                    ForEach(model.archived, id: \.self) { name in
                        LabeledContent(name) {
                            Button(L10n.agentSkillRestore) { Task { await model.restore(name) } }
                                .buttonStyle(.dahlia())
                        }
                    }
                }
            } header: {
                AgentSectionHeader(title: L10n.agentSkillCurator) { EmptyView() }
            }
            SkillOptimizerSection(model: model)
            if model.runs["review"]?.isEmpty == false {
                Section {
                    AgentSystemRunRows(model: model, task: "review", title: L10n.agentLegacyReviewRuns)
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
}

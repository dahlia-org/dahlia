import SwiftUI

/// Settings → Memory for the open account: Hermes memory, its review after conversations, and its change history.
struct MemorySettingsView: View {
    var body: some View {
        AgentMemorySettingsView()
    }
}

struct AgentMemorySettingsView: View {
    @Environment(MainWindowNavigation.self) private var navigation
    @State private var model: AgentLearningSettingsModel
    @State private var history: AgentOptimizationSettingsModel
    @AppStorage private var memoryEnabled: Bool
    @AppStorage private var memoryReview: Bool
    @AppStorage private var memoryInterval: Int
    @State private var confirmClear = false
    @State private var models: [CodexModel] = []

    init() {
        _model = State(initialValue: AgentLearningSettingsModel())
        _history = State(initialValue: AgentOptimizationSettingsModel(tasks: ["memoryReview", "review"]))
        let key = AppAccount.key
        _memoryEnabled = AppStorage(wrappedValue: true, AgentLearningSettings.memoryKey(key))
        // Starts from the single review switch that skill and memory organization replaced.
        _memoryReview = AppStorage(wrappedValue: AgentLearningSettings.legacyReviewEnabled(key), AgentLearningSettings.memoryReviewKey(key))
        _memoryInterval = AppStorage(wrappedValue: AgentLearningSettings.memoryInterval(key), AgentLearningSettings.memoryIntervalKey(key))
    }

    var body: some View {
        Form {
            Section {
                SettingsInfoToggle(title: L10n.agentMemoryEnabled, help: L10n.agentLearningDefaultHelp, isOn: $memoryEnabled)
                SettingsInfoToggle(title: L10n.agentMemoryReviewEnabled, help: L10n.agentMemoryReviewHelp, isOn: $memoryReview)
                    .disabled(!memoryEnabled)
                Group {
                    Picker(L10n.agentReviewInterval, selection: $memoryInterval) {
                        ForEach(AgentLearningSettings.reviewIntervalChoices, id: \.self) { count in
                            Text(L10n.agentMemoryReviewEvery(count)).font(.dahliaBody).tag(count)
                        }
                    }
                    AgentReviewModelRows(kind: .memory, models: models)
                }
                .disabled(!memoryEnabled || !memoryReview)
                AgentSystemRunRows(model: history, task: "memoryReview", title: L10n.agentReviewRuns)
            }
            ForEach(["user", "memory"], id: \.self) { target in
                Section {
                    LabeledContent(target == "user" ? L10n.agentMemoryUser : L10n.agentMemoryEnvironment) {
                        Text(AgentMemoryService.usage(model.memories.filter { $0.target == target }, target: target))
                    }
                    ForEach(model.memories.filter { $0.target == target }) { entry in
                        HStack {
                            Text(entry.content).textSelection(.enabled)
                            Spacer()
                            Text(entry.createdBy == "user" ? L10n.agentMemoryByUser : L10n.agentMemoryByAgent).foregroundStyle(.secondary)
                            Button(L10n.edit) { edit(target: target, entry: entry) }
                            Button(L10n.delete, role: .destructive) { Task { await model.remove([entry]) } }
                        }
                    }
                    Button(L10n.add) { edit(target: target, entry: nil) }
                }
            }
            Section {
                AgentLearningChangesView(model: model, kind: "memory")
                Button(L10n.agentMemoryClear, role: .destructive) { confirmClear = true }.disabled(model.memories.isEmpty)
            }
            if history.runs["review"]?.isEmpty == false {
                Section {
                    AgentSystemRunRows(model: history, task: "review", title: L10n.agentLegacyReviewRuns)
                }
            }
            if let error = history.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped).toggleStyle(.dahliaSwitch)
        .font(.dahliaBody)
        .disabled(model.isBusy)
        .task {
            await model.refresh()
            await history.refresh()
            models = await (try? PiRuntimeService.shared.models(forceRefresh: false))?.filter { !$0.hidden } ?? []
        }
        .onChange(of: memoryEnabled) { Task { await PiChatService.shared.drainLearningWork() } }
        .onChange(of: memoryReview) { Task { await PiChatService.shared.drainLearningWork() } }
        .confirmationDialog(L10n.agentMemoryClear, isPresented: $confirmClear) {
            Button(L10n.delete, role: .destructive) { Task { await model.remove(model.memories) } }
        }
    }

    private func edit(target: String, entry: AgentMemoryRecord?) {
        navigation
            .presentSettingsModal(AgentMemoryEditor(
                model: model,
                target: target,
                content: entry?.content ?? "",
                onClose: navigation.dismissSettingsModal
            ) { content in
                Task {
                    await model.saveMemory(target: target, content: content, replacing: entry)
                    if model.error == nil { navigation.dismissSettingsModal() }
                }
            })
    }
}

import SwiftUI

struct AgentMemorySettingsView: View {
    let account: CodexRuntimeProvider
    @Environment(MainWindowNavigation.self) private var navigation
    @State private var model: AgentLearningSettingsModel
    @AppStorage private var memoryEnabled: Bool
    @AppStorage private var reviewEnabled: Bool
    @State private var confirmClear = false

    init(account: CodexRuntimeProvider) {
        self.account = account
        _model = State(initialValue: AgentLearningSettingsModel(account: account))
        _memoryEnabled = AppStorage(wrappedValue: true, AgentLearningSettings.memoryKey(account.accountKey))
        _reviewEnabled = AppStorage(wrappedValue: true, AgentLearningSettings.reviewKey(account.accountKey))
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.agentMemoryEnabled, isOn: $memoryEnabled)
                Toggle(L10n.agentLearningEnabled, isOn: $reviewEnabled)
                Text(L10n.agentLearningDefaultHelp).foregroundStyle(.secondary)
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
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped).toggleStyle(.switch)
        .font(.dahliaBody)
        .disabled(model.isBusy)
        .task { await model.refresh() }
        .onChange(of: memoryEnabled) { Task { await PiChatService.shared.drainLearningWork() } }
        .onChange(of: reviewEnabled) { Task { await PiChatService.shared.drainLearningWork() } }
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

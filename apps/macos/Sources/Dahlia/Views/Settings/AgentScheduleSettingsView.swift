import SwiftUI

struct AgentScheduleSettingsView: View {
    @State private var model: AgentLearningSettingsModel
    @State private var resuming: ChatScheduleRecord?
    @State private var deleting: ChatScheduleRecord?
    init() { _model = State(initialValue: AgentLearningSettingsModel()) }
    var body: some View {
        Form {
            Section {
                Text(L10n.agentScheduleHelp).foregroundStyle(.secondary)
                if model.schedules.isEmpty { Text(L10n.agentSchedulesEmpty).foregroundStyle(.secondary) }
                ForEach(model.schedules) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(row.name).font(.dahliaHeadline)
                            Spacer()
                            Button(row.enabled ? L10n.agentSchedulePause : L10n.agentScheduleResume) {
                                if row.enabled { Task { await model.schedule(row, action: "pause") } } else { resuming = row }
                            }
                            Button(L10n.agentScheduleRun) { Task { await model.schedule(row, action: "run") } }.disabled(!row.enabled)
                            Button(L10n.agentScheduleOpen) { NotificationCenter.default.post(
                                name: AgentLearningSettings.openThread,
                                object: row.threadID
                            )
                            }
                            Button(L10n.delete, role: .destructive) { deleting = row }
                        }
                        Text(row.schedule).textSelection(.enabled)
                        Text(row.prompt).textSelection(.enabled)
                        Text(row.enabled && AgentBackgroundActivity.isRecording ? L10n.agentScheduleWaitingRecording : L10n
                            .agentScheduleStatus(model.scheduleStates[row.id] ?? "idle"))
                            .foregroundStyle(.secondary)
                        if let next = row.nextFireAt, row.enabled { Text(next.formatted(date: .abbreviated, time: .shortened)) }
                        Toggle(
                            L10n.agentScheduleNotify,
                            isOn: Binding(get: { row.notify }, set: { enabled in Task { await model.notification(row, enabled: enabled) } })
                        )
                    }
                    .padding(.vertical, 4)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped).toggleStyle(.dahliaSwitch).font(.dahliaBody).disabled(model.isBusy)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .confirmationDialog(L10n.agentScheduleApproval, isPresented: Binding(get: { resuming != nil }, set: { if !$0 { resuming = nil } })) {
            if let row = resuming { Button(L10n.agentScheduleResume) { Task { await model.schedule(row, action: "resume", approved: true) }
                resuming = nil
            } }
        } message: {
            if let row = resuming {
                let tools = (try? JSONDecoder().decode([String].self, from: Data(row.allowedTools.utf8))) ?? []
                Text("\(row.schedule)\n\(row.prompt)\n\(row.skills)\n\(tools.filter { $0.hasPrefix("mcp__") }.joined(separator: ", "))")
            }
        }
        .confirmationDialog(L10n.delete, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let row = deleting { Button(L10n.delete, role: .destructive) { Task { await model.schedule(row, action: "remove") }
                deleting = nil
            } }
        }
    }
}

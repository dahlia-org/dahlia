import SwiftUI

struct AgentLearningChangesView: View {
    let model: AgentLearningSettingsModel
    let kind: String

    var body: some View {
        ForEach(model.changes.filter { $0.kind == kind }) { change in
            DisclosureGroup {
                if let before = model.changePreviews[change.id]?.before { Text(before).textSelection(.enabled).foregroundStyle(.secondary) }
                if let after = model.changePreviews[change.id]?.after { Text(after).textSelection(.enabled) }
                HStack {
                    if change.status == "pending" {
                        Button(L10n.agentLearningApprove) { Task { await model.resolve(change, action: "approve") } }
                        Button(L10n.agentLearningDiscard) { Task { await model.resolve(change, action: "discard") } }
                    } else if change.status == "applied" {
                        Button(L10n.agentLearningUndo) { Task { await model.resolve(change, action: "undo") } }
                    }
                }
                .disabled(model.isBusy)
            } label: {
                VStack(alignment: .leading) {
                    Text(change.kind == "skill" ? change.target : L10n.agentMemory)
                    Text(change.createdAt, style: .date).foregroundStyle(.secondary)
                    Text(change.status == "pending" ? L10n.agentLearningPending : change.status == "applied" ? L10n.agentLearningApplied : L10n
                        .agentLearningClosed)
                        .font(.dahliaSecondary).foregroundStyle(.secondary)
                }
            }
        }
    }

}

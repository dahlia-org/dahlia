import SwiftUI

struct CodexChatRelatedThreadsView: View {
    let parentID: String
    @Bindable var coordinator: CodexChatCoordinator
    let onOpen: (CodexChatThreadSummary) -> Void
    @State private var threads: [CodexChatThreadSummary] = []
    @State private var error: String?
    @State private var deciding: Set<String> = []

    private var revision: String {
        coordinator.runtimeStates.map { "\($0.threadID):\($0.turnID):\($0.status):\($0.approvals.map(\.id).joined())" }.sorted()
            .joined(separator: ",")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(threads) { thread in
                    HStack {
                        Button { onOpen(thread) } label: {
                            Label(thread.title.nilIfBlank ?? L10n.newChat, systemImage: "bubble.left.and.bubble.right")
                                .lineLimit(1)
                        }
                        .buttonStyle(.borderless)
                        Spacer(minLength: 4)
                        Text(L10n.chatRunStatus(thread.status))
                            .foregroundStyle(.secondary)
                        if ["queued", "running", "waitingForUser"].contains(thread.status) {
                            Button(L10n.stopGenerating, systemImage: "stop.fill") {
                                Task { await coordinator.stopThread(thread.id) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                    .font(.dahliaSecondary)
                    if let state = coordinator.runtimeStates.first(where: { $0.threadID == thread.id }) {
                        ForEach(state.approvals) { request in
                            CodexChatApprovalView(request: request, isDecisionEnabled: !deciding.contains(request.id)) { id, decision in
                                deciding.insert(id)
                                Task {
                                    defer { deciding.remove(id) }
                                    do {
                                        try await coordinator.decideRelatedApproval(state, id: id, decision: decision)
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
                if let error { Text(error).font(.dahliaSecondary).foregroundStyle(.red) }
            }
            .padding(.vertical, threads.isEmpty ? 0 : 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: threads.isEmpty ? 0 : 240)
        .task(id: parentID + revision) {
            do {
                let loaded = try await coordinator.relatedThreads(parentID: parentID)
                try Task.checkCancellation()
                threads = loaded
                error = nil
            } catch is CancellationError {
                // Closing the view discards only this projection.
            } catch { self.error = error.localizedDescription }
        }
    }
}

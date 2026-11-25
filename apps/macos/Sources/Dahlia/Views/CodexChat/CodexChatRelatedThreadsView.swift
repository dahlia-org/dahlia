import SwiftUI

struct CodexChatRelatedThreadsView: View {
    let threads: [CodexChatThreadSummary]
    @Bindable var coordinator: CodexChatCoordinator
    let onOpen: (CodexChatThreadSummary) -> Void
    @State private var error: String?
    @State private var deciding: Set<String> = []
    @State private var isExpanded = true
    @State private var isHeaderHovered = false

    var body: some View {
        VStack(spacing: 4) {
            if threads.count > 1 {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 10) {
                        Image.piLogo
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.chatRelatedThreadCount(threads.count))
                                .font(.dahliaBody)
                            let activeCount = threads.filter { ["queued", "running", "waitingForUser"].contains($0.status) }.count
                            if activeCount > 0 {
                                Text(L10n.chatActiveThreadCount(activeCount))
                                    .font(.dahliaSecondary)
                                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .accessibilityHidden(true)
                    }
                    .padding(10)
                    .contentShape(.rect)
                    .background(isHeaderHovered ? DahliaDesign.contentHighlightColor : .clear, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .onHover { isHeaderHovered = $0 }
                .accessibilityValue(isExpanded ? L10n.collapse : L10n.expand)
            }
            if threads.count <= 1 || isExpanded {
                threadList
            }
        }
        .padding(.vertical, threads.isEmpty ? 0 : 2)
    }

    private var threadList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(threads) { thread in
                CodexChatRelatedThreadRow(thread: thread, meetingNamesByID: coordinator.dockedSession.meetingNamesByID) {
                    onOpen(thread)
                } onStop: {
                    Task { await coordinator.stopThread(thread.id) }
                }
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
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .padding(.top, 4)
                    }
                }
            }
            if let error { Text(error).font(.dahliaSecondary).foregroundStyle(.red) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(threads.isEmpty ? .clear : DahliaDesign.secondaryTextColor.opacity(0.3), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

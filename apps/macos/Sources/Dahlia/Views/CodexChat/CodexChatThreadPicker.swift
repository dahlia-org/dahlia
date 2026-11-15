import SwiftUI

struct CodexChatThreadPicker: View {
    let session: CodexChatSessionModel
    let onSelect: (CodexChatThreadSummary) -> Void
    @State private var threads: [CodexChatThreadSummary] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(threads) { thread in
                    CodexChatConfigurationRow(
                        title: thread.title.nilIfBlank ?? L10n.newChat,
                        isSelected: false,
                        leadingSystemImage: "bubble.left.and.bubble.right"
                    ) { onSelect(thread) }
                }
                if loading { ProgressView().controlSize(.small).padding(8) }
                if cursor != nil {
                    Button(L10n.loadMore) { Task { await loadMore() } }
                        .buttonStyle(.borderless)
                        .disabled(loading)
                }
                if let error { Text(error).font(.dahliaSecondary).foregroundStyle(.red).padding(8) }
                if threads.isEmpty, !loading, error == nil { Text(L10n.noRecentChats).font(.dahliaBody).padding(8) }
            }
            .padding(8)
        }
        .task { await loadMore() }
    }

    private func loadMore() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await session.referenceThreads(cursor: cursor)
            try Task.checkCancellation()
            threads += page.threads.filter { $0.id != session.backendThreadID }
            cursor = page.nextCursor
            error = nil
        } catch is CancellationError {
            // Closing the view discards only this projection.
        } catch { self.error = error.localizedDescription }
    }
}

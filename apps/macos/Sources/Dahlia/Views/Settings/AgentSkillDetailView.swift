import SwiftUI

struct AgentSkillDetailView: View {
    let skill: CodexChatSlashCommand
    let onClose: () -> Void
    @State private var content: String?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Button(action: onClose) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                Text(skill.displayName)
                    .font(.dahliaTitle2)
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let description = skill.description {
                            Text(description).foregroundStyle(.secondary)
                        }
                        if let content {
                            CodexChatMarkdownView(markdown: content)
                        } else if let errorMessage {
                            Text(errorMessage).foregroundStyle(.red)
                        } else if skill.skillFileURL == nil {
                            Text(L10n.agentSkillContentUnavailable).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button(L10n.close, action: onClose)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, maxHeight: 600)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
            .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        }
        .font(.dahliaBody)
        .transition(.identity)
        .task { await loadContent() }
    }

    private func loadContent() async {
        guard let file = skill.skillFileURL else { return }
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try String(contentsOf: file, encoding: .utf8)
            }.value
            guard !Task.isCancelled else { return }
            content = text
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

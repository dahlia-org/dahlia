import SwiftUI

struct AgentSkillSettingsView: View {
    let account: CodexRuntimeProvider
    @State private var skills: [CodexChatSlashCommand] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var refreshID = 0

    var body: some View {
        Form {
            Section {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                } else if skills.isEmpty {
                    Text(L10n.agentSkillsEmpty).foregroundStyle(.secondary)
                }
                ForEach(skills) { skill in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.name).font(.dahliaHeadline)
                        if let description = skill.description {
                            Text(description)
                        }
                        if let path = skill.sourceInfo?.path {
                            Text(path)
                                .font(.dahliaSecondary)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }
            } header: {
                AgentSectionHeader(title: L10n.agentSkills) {
                    Button(L10n.reload, systemImage: "arrow.clockwise") { refreshID += 1 }
                        .disabled(isLoading)
                }
            } footer: {
                Text(L10n.agentSkillsHelp)
            }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task(id: refreshID) { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await PiRuntimeService.shared.skills(for: account)
            guard !Task.isCancelled else { return }
            skills = result
        } catch {
            guard !Task.isCancelled else { return }
            skills = []
            errorMessage = error.localizedDescription
        }
    }
}

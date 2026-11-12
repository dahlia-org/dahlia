import AppKit
import SwiftUI

struct AgentSkillSettingsView: View {
    let account: CodexRuntimeProvider
    @Environment(MainWindowNavigation.self) private var navigation
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
                        HStack {
                            Text(skill.displayName).font(.dahliaHeadline)
                            Spacer()
                            Button(L10n.agentSkillOpenFolder, systemImage: "folder") { openFolder(for: skill) }
                                .disabled(skill.skillFileURL == nil)
                                .help(L10n.agentSkillOpenFolder)
                                .accessibilityLabel(Text("\(L10n.agentSkillOpenFolder): \(skill.displayName)"))
                            Button(L10n.agentSkillDetails, systemImage: "info.circle") {
                                navigation.presentSettingsModal(AgentSkillDetailView(skill: skill, onClose: navigation.dismissSettingsModal))
                            }
                            .help(L10n.agentSkillDetails)
                            .accessibilityLabel(Text("\(L10n.agentSkillDetails): \(skill.displayName)"))
                        }
                        .buttonStyle(.dahlia())
                        if let description = skill.description {
                            Text(description)
                                .lineLimit(2)
                                .truncationMode(.tail)
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

    private func openFolder(for skill: CodexChatSlashCommand) {
        guard let file = skill.skillFileURL else { return }
        if !NSWorkspace.shared.open(file.deletingLastPathComponent()) {
            errorMessage = L10n.agentSkillOpenFolderFailed
        }
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

import AppKit
import DahliaRuntimeSupport
import SwiftUI

struct AgentSkillSettingsView: View {
    let account: CodexRuntimeProvider
    let readOnly: Bool
    @Environment(MainWindowNavigation.self) private var navigation
    @State private var learning: AgentLearningSettingsModel
    @State private var curation: [String: SkillCurationState] = [:]
    @State private var root: URL?
    @State private var entries: [AgentSkillSettingsEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var refreshID = 0
    @State private var deleting: String?

    init(account: CodexRuntimeProvider, readOnly: Bool = false) {
        self.account = account
        self.readOnly = readOnly
        _learning = State(initialValue: AgentLearningSettingsModel(account: account))
    }

    var body: some View {
        Form {
            Section {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                } else if entries.isEmpty {
                    Text(L10n.agentSkillsEmpty).foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.name).font(.dahliaHeadline)
                            Text(provenanceLabel(entry)).font(.dahliaSecondary).foregroundStyle(.secondary)
                            Spacer()
                            if !entry.isReadOnly, curation[entry.name]?.isCuratorManaged == true {
                                let pinned = curation[entry.name]?.pinned == true
                                Button(pinned ? L10n.agentSkillPin + " ✓" : L10n.agentSkillPin) {
                                    Task {
                                        do {
                                            let service = try await PiChatService.shared.skillService()
                                            try await service.setPinned(name: entry.name, account: account.accountKey, pinned: !pinned)
                                            await refresh()
                                        } catch { errorMessage = error.localizedDescription }
                                    }
                                }
                                .help(L10n.agentSkillPinHelp)
                            }
                            if !entry.isReadOnly {
                                Button(curation[entry.name]?.locked == true ? L10n.agentSkillLock + " ✓" : L10n.agentSkillLock) {
                                    Task {
                                        do {
                                            let service = try await PiChatService.shared.skillService()
                                            try await service.setLocked(
                                                name: entry.name,
                                                account: account.accountKey,
                                                locked: curation[entry.name]?.locked != true
                                            )
                                            await refresh()
                                        } catch { errorMessage = error.localizedDescription }
                                    }
                                }

                            }
                            if !entry.isReadOnly {
                                AgentSkillActionsMenu(
                                    managed: curation[entry.name]?.isCuratorManaged == true,
                                    onEdit: entry.skill?.skillFileURL.map { _ in { edit(entry.name) } },
                                    onToggleCuration: { setCuratorManaged(entry.name, managed: curation[entry.name]?.isCuratorManaged != true) },
                                    onDelete: { deleting = entry.name }
                                )
                                .accessibilityLabel(Text("\(L10n.agentSkillActions): \(entry.name)"))
                            }
                            if let skill = entry.skill {
                                Button(L10n.agentSkillOpenFolder, systemImage: "folder") { openFolder(for: skill) }
                                    .disabled(skill.skillFileURL == nil)
                                    .help(L10n.agentSkillOpenFolder)
                                    .accessibilityLabel(Text("\(L10n.agentSkillOpenFolder): \(entry.name)"))
                                Button(L10n.agentSkillDetails, systemImage: "info.circle") {
                                    navigation.presentSettingsModal(AgentSkillDetailView(skill: skill, onClose: navigation.dismissSettingsModal))
                                }
                                .help(L10n.agentSkillDetails)
                                .accessibilityLabel(Text("\(L10n.agentSkillDetails): \(entry.name)"))
                            }
                        }
                        .buttonStyle(.dahlia())
                        if let description = entry.skill?.description {
                            Text(description)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        } else if entry.skill == nil {
                            Text(curation[entry.name]?.state == "archived" ? L10n.agentSkillArchived : L10n.agentSkillUnavailable)
                                .foregroundStyle(.secondary)
                        }
                        if learning.changes.contains(where: { $0.kind == "skill" && $0.target == entry.name }) {
                            DisclosureGroup(L10n.agentSkillHistory) {
                                AgentLearningChangesView(model: learning, kind: "skill", target: entry.name, allowsChanges: !entry.isReadOnly)
                            }
                            .disclosureGroupStyle(MCPDisclosureGroupStyle())
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
            if let error = learning.error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task(id: refreshID) { await refresh() }
        .confirmationDialog(
            L10n.agentSkillDeleteConfirm(deleting ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(L10n.delete, role: .destructive) { if let name = deleting { delete(name) } }
        } message: {
            Text(L10n.agentSkillDeleteHelp)
        }
        .onChange(of: learning.isBusy) { wasBusy, isBusy in
            if wasBusy, !isBusy { refreshID += 1 }
        }
    }

    /// The group that decides whether the Curator may touch the skill.
    private func provenanceLabel(_ entry: AgentSkillSettingsEntry) -> String {
        switch entry.provenance {
        case .bundled: return L10n.agentSkillProvenanceBundled
        case .package: return L10n.agentSkillProvenancePackage
        case .account:
            guard let state = curation[entry.name], state.isCuratorManaged else { return L10n.agentSkillProvenanceUser }
            return state.state == "stale" ? L10n.agentSkillProvenanceStale : L10n.agentSkillProvenanceCurated
        }
    }

    private func edit(_ name: String) {
        navigation.presentSettingsModal(AgentSkillEditor(account: account, name: name, onClose: navigation.dismissSettingsModal) {
            navigation.dismissSettingsModal()
            refreshID += 1
        })
    }

    /// An account skill deletion whose history can restore it.
    private func delete(_ name: String) {
        Task {
            do {
                let service = try await PiChatService.shared.skillService()
                let root = try await PiChatService.shared.skillsRoot(account)
                let operation: JSONValue = .object(["action": .string("delete"), "name": .string(name)])
                _ = try await service.manageAccountSkills(
                    payload: .object(["operations": .array([operation])]), account: account.accountKey, root: root
                )
                refreshID += 1
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func setCuratorManaged(_ name: String, managed: Bool) {
        Task {
            do {
                let service = try await PiChatService.shared.skillService()
                try await service.setCuratorManaged(name: name, account: account.accountKey, managed: managed)
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
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
            let service = try await PiChatService.shared.skillService()
            curation = try await Dictionary(
                service.curationStates(account: account.accountKey).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
            )
            root = try await PiChatService.shared.skillsRoot(account)
            await learning.refresh()
            guard !Task.isCancelled, let root else { return }
            let grouped = try await AgentSkillSettingsEntry.grouped(skills: result, changes: learning.changes, root: root)
            guard !Task.isCancelled else { return }
            entries = grouped
                .filter { $0.isReadOnly == readOnly }
        } catch {
            guard !Task.isCancelled else { return }
            entries = []
            errorMessage = error.localizedDescription
        }
    }
}

/// Edit, hand to or take back from the Curator, and delete one account skill.
private struct AgentSkillActionsMenu: View {
    let managed: Bool
    let onEdit: (() -> Void)?
    let onToggleCuration: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        Menu {
            if let onEdit { Button(L10n.edit, systemImage: "pencil", action: onEdit) }
            Button(managed ? L10n.agentSkillStopCuration : L10n.agentSkillStartCuration, systemImage: "wand.and.sparkles", action: onToggleCuration)
            Divider()
            Button(L10n.delete, systemImage: "trash", role: .destructive, action: onDelete)
        } label: {
            Label(L10n.agentSkillActions, systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .padding(6)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(isHovered ? .primary : .secondary)
        .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .help(L10n.agentSkillActions)
    }
}

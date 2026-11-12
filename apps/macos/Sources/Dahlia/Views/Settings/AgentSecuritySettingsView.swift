import AppKit
import SwiftUI

struct AgentSecuritySettingsView: View {
    @State private var model: PiFileAccessSettingsModel
    @AppStorage private var workingDirectory: String

    init(account: CodexRuntimeProvider) {
        _model = State(initialValue: PiFileAccessSettingsModel(account: account))
        _workingDirectory = AppStorage(wrappedValue: "", PiWorkingDirectory.defaultsKey(for: account))
    }

    var body: some View {
        Form {
            Section {
                TextField(L10n.agentWorkingDirectory, text: $workingDirectory, prompt: Text(PiWorkingDirectory.defaultPath))
                    .help(L10n.agentWorkingDirectoryHelp)
                Text(L10n.agentFileAccessDefaults)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.agentSecurity).font(.dahliaSectionHeader)
            }
            Section {
                ForEach(model.defaultAccess.resources) { grant in
                    defaultAccessRow(grant)
                }
                DisclosureGroup(L10n.agentFileAccessDahliaData) {
                    Text(L10n.agentFileAccessDahliaDataHelp)
                        .foregroundStyle(.secondary)
                    ForEach(model.defaultAccess.data) { grant in
                        defaultAccessRow(grant)
                    }
                }
                DisclosureGroup(L10n.agentFileAccessSystemFolders) {
                    ForEach(model.defaultAccess.system) { grant in
                        defaultAccessRow(grant)
                    }
                }
            } header: {
                Text(L10n.agentFileAccessBuiltIn).font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.agentFileAccessBuiltInHelp)
            }
            Section {
                ForEach(model.settings.grants) { grant in
                    LabeledContent {
                        HStack {
                            Picker(L10n.agentFileAccessPermission, selection: accessBinding(for: grant)) {
                                Text(L10n.agentFileAccessReadOnly).font(.dahliaBody).tag(PiFileAccessSettings.Access.readOnly)
                                Text(L10n.agentFileAccessReadWrite).font(.dahliaBody).tag(PiFileAccessSettings.Access.readWrite)
                            }
                            .labelsHidden()
                            .accessibilityLabel(Text("\(L10n.agentFileAccessPermission): \(grant.path)"))
                            Button(L10n.agentFileAccessRemove, systemImage: "trash") { model.remove(grant.id) }
                                .labelStyle(.iconOnly)
                                .help(L10n.agentFileAccessRemove)
                                .accessibilityLabel(Text("\(L10n.agentFileAccessRemove): \(grant.path)"))
                        }
                    } label: {
                        Label {
                            Text((grant.path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(grant.path)
                        } icon: {
                            Image(systemName: grant.isDirectory ? "folder" : "doc")
                        }
                    }
                }
                Button(L10n.agentFileAccessAdd, systemImage: "plus") { choosePaths() }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(L10n.agentFileAccess).font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.agentFileAccessHelp)
            }
            .disabled(model.isUpdating)
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task(id: workingDirectory) { await model.refreshDefaults(workingDirectory: workingDirectory) }
    }

    private func defaultAccessRow(_ grant: PiFileAccessSettings.Grant) -> some View {
        LabeledContent {
            Text(grant.access == .readWrite ? L10n.agentFileAccessReadWrite : L10n.agentFileAccessReadOnly)
                .foregroundStyle(.secondary)
        } label: {
            Label {
                Text((grant.path as NSString).abbreviatingWithTildeInPath)
                    .textSelection(.enabled)
                    .help(grant.path)
            } icon: {
                Image(systemName: grant.isDirectory ? "folder" : "doc")
            }
        }
    }

    private func accessBinding(for grant: PiFileAccessSettings.Grant) -> Binding<PiFileAccessSettings.Access> {
        Binding(get: { grant.access }, set: { access in
            Task { await model.setAccess(access, for: grant.id) }
        })
    }

    private func choosePaths() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.prompt = L10n.add
        panel.begin { response in
            guard response == .OK else { return }
            Task { await model.add(panel.urls) }
        }
    }
}

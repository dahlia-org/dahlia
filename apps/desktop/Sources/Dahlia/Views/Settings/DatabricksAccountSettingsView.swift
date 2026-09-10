import SwiftUI

struct DatabricksAccountSettingsView<LeadingContent: View>: View {
    @Bindable private var vaultSettings = VaultAISettingsModel.shared
    let controller: DatabricksAccountController
    let title: String
    let footer: String?
    let leadingContent: LeadingContent
    @State private var workspaceURL = ""
    @State private var signInTask: Task<Void, Never>?

    init(
        controller: DatabricksAccountController,
        title: String,
        footer: String? = nil,
        @ViewBuilder leadingContent: () -> LeadingContent
    ) {
        self.controller = controller
        self.title = title
        self.footer = footer
        self.leadingContent = leadingContent()
    }

    var body: some View {
        Section {
            leadingContent
            Picker(L10n.databricksProfile, selection: $vaultSettings.databricksProfile) {
                Text(L10n.notSelected).tag("")
                if !vaultSettings.databricksProfile.isEmpty,
                   !controller.connections.contains(where: { $0.id.uuidString == vaultSettings.databricksProfile }) {
                    Text(L10n.dahliaNotSignedIn).tag(vaultSettings.databricksProfile)
                }
                ForEach(controller.connections) { connection in
                    Text(connection.name).tag(connection.id.uuidString)
                }
            }
            .disabled(controller.isBusy)
            if let selected = controller.connections.first(where: { $0.id.uuidString == vaultSettings.databricksProfile }) {
                LabeledContent(L10n.databricksWorkspaceURL, value: selected.host)
                Button(L10n.signOut) {
                    signInTask = Task {
                        if await controller.remove(selected.id), vaultSettings.databricksProfile == selected.id.uuidString {
                            vaultSettings.databricksProfile = ""
                        }
                    }
                }
                .buttonStyle(.dahlia())
                .disabled(controller.isBusy)
            } else if !vaultSettings.databricksProfile.isEmpty {
                Text(L10n.databricksReconnectRequired).foregroundStyle(.secondary)
            }
            TextField(
                L10n.databricksWorkspaceURL,
                text: $workspaceURL,
                prompt: Text(L10n.databricksWorkspaceURLPlaceholder)
            )
            .textContentType(.URL)
            .disabled(controller.isBusy)
            .onSubmit(signIn)
            if controller.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.codexWaitingForBrowserSignIn)
                    Button(L10n.cancelSignIn) { signInTask?.cancel() }
                        .buttonStyle(.dahlia())
                }
            } else {
                Button(L10n.signInWithDatabricks, action: signIn)
                    .buttonStyle(.dahlia(.primary))
                    .disabled(workspaceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = controller.errorMessage {
                SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red)
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
        .task { await controller.load() }
        .onDisappear { signInTask?.cancel() }
    }

    private func signIn() {
        guard !controller.isBusy else { return }
        signInTask = Task {
            if let id = await controller.signIn(workspaceURL: workspaceURL), !Task.isCancelled {
                vaultSettings.databricksProfile = id
                workspaceURL = ""
            }
        }
    }
}

extension DatabricksAccountSettingsView where LeadingContent == EmptyView {
    init(controller: DatabricksAccountController = DatabricksAccountController()) {
        self.init(controller: controller, title: L10n.databricks) { EmptyView() }
    }
}

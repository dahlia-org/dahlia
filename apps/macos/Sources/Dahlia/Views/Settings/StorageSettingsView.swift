import SwiftUI

/// Where each storage provider keeps Dahlia's files. Folders and volumes have fixed names, so this page only shows them;
/// the one setting, a Databricks catalog and schema, is offered only while it is missing.
struct StorageSettingsView: View {
    @Environment(MainWindowNavigation.self) private var navigation
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var googleAccounts = GoogleProviderAccountsModel.shared

    var body: some View {
        Form {
            Section {
                ForEach(googleAccounts.controllers) { google in
                    StorageLocationRow(title: google.displayName, icon: .googleLogo, accountID: google.id) {
                        try await ProviderAccount.google(connectionID: google.id).backupLocationDescription()
                    }
                }
                ForEach(workspaceSettings.databricksConnections) { connection in
                    StorageLocationRow(title: connection.displayName, icon: .databricksLogo, accountID: connection.id) {
                        try await ProviderAccount.databricks(connectionID: connection.id).backupLocationDescription()
                    } unset: {
                        Button(L10n.databricksCatalogSchemaEdit) { navigation.editDatabricksCatalogSchema(for: connection) }
                            .buttonStyle(.dahlia())
                    }
                }
                if googleAccounts.controllers.isEmpty, workspaceSettings.databricksConnections.isEmpty {
                    Text(L10n.storageNoProviders).foregroundStyle(.secondary)
                }
                Button(L10n.manageProviders) { navigation.openSettings(category: .providers) }
                    .buttonStyle(.dahlia())
                if let error = googleAccounts.errorMessage {
                    SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
                }
            } header: {
                Text(L10n.storageLocations).font(.dahliaSectionHeader)
            } footer: {
                Text(L10n.storageLocationChangeDescription)
            }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task { await googleAccounts.activate() }
    }
}

/// One provider and its location. A nil location means the provider still needs a setting, which `unset` offers.
private struct StorageLocationRow<Unset: View>: View {
    let title: String
    let icon: Image
    let accountID: UUID
    let load: @MainActor () async throws -> String?
    @ViewBuilder var unset: Unset
    @State private var location: String?
    @State private var isLoaded = false
    @State private var errorMessage: String?
    @State private var revision = 0

    init(
        title: String,
        icon: Image,
        accountID: UUID,
        load: @escaping @MainActor () async throws -> String?,
        @ViewBuilder unset: () -> Unset = { EmptyView() }
    ) {
        self.title = title
        self.icon = icon
        self.accountID = accountID
        self.load = load
        self.unset = unset()
    }

    var body: some View {
        LabeledContent {
            if isLoaded, location == nil { unset }
        } label: {
            Label {
                Text(title)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.orange)
                } else if let location {
                    Text(location).foregroundStyle(.secondary).textSelection(.enabled)
                } else if !isLoaded {
                    ProgressView().controlSize(.small)
                }
            } icon: {
                icon.resizable().scaledToFit().frame(width: 16, height: 16)
            }
        }
        .task(id: revision) {
            do {
                let value = try await load()
                try Task.checkCancellation()
                location = value
                isLoaded = true
                errorMessage = nil
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProviderAccountSettings.didChange(accountID: accountID))) { _ in revision += 1 }
    }
}

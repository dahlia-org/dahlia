import SwiftUI

struct StorageSettingsView: View {
    @Environment(MainWindowNavigation.self) private var navigation
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var googleAccounts = GoogleProviderAccountsModel.shared

    var body: some View {
        Form {
            Section {
                Button(L10n.manageProviders) { navigation.openSettings(category: .providers) }
                    .buttonStyle(.dahlia())
            } footer: {
                Text(L10n.storageLocationChangeDescription)
            }
            ForEach(googleAccounts.controllers) { google in
                GoogleDriveStorageSettingsSection(accountID: google.id, name: google.displayName)
            }
            ForEach(workspaceSettings.databricksConnections) { connection in
                Section {
                    DatabricksCatalogSchemaLabel(connectionID: connection.id)
                    Button(L10n.databricksCatalogSchemaEdit) { navigation.editDatabricksCatalogSchema(for: connection) }
                        .buttonStyle(.dahlia())
                } header: {
                    Text("\(connection.displayName) · Databricks").font(.dahliaSectionHeader)
                } footer: {
                    Text(L10n.storageDatabricksVolumeDescription)
                }
            }
            if let error = googleAccounts.errorMessage {
                Section { SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange) }
            }
        }
        .formStyle(.grouped)
        .font(.dahliaBody)
        .task { await googleAccounts.activate() }
    }
}

import SwiftUI

struct GoogleDriveStorageSettingsSection: View {
    let accountID: UUID
    let name: String
    @State private var location = ""
    @State private var savedLocation = ""
    @State private var isLoaded = false
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if isLoaded {
                Group {
                    LabeledContent(L10n.storageDefaultFolder) {
                        TextField(GoogleDriveStorageLocation.defaultFolderName, text: $location)
                    }
                    LabeledContent(L10n.backups, value: "My Drive/\(savedLocation)/backup")
                    if !isValid {
                        SettingsStatusMessage(text: L10n.storageFolderInvalid, systemImage: "exclamationmark.triangle", tint: .orange)
                    }
                    HStack {
                        Button(L10n.save) { Task { await save() } }.buttonStyle(.dahlia(.primary))
                            .disabled(!isValid || location == savedLocation)
                        Button(L10n.cancel) { location = savedLocation }.buttonStyle(.dahlia())
                            .disabled(location == savedLocation)
                        Button(L10n.storageRestoreDefault) { location = GoogleDriveStorageLocation.defaultFolderName }
                            .buttonStyle(.dahlia())
                            .disabled(location == GoogleDriveStorageLocation.defaultFolderName)
                    }
                }
                .disabled(isBusy)
            }
            if isBusy { ProgressView().controlSize(.small) }
            if let errorMessage {
                SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle", tint: .orange)
                if !isLoaded { Button(L10n.reload) { Task { await load() } }.disabled(isBusy) }
            }
        } header: {
            Text("\(name) · \(L10n.googleDrive)").font(.dahliaSectionHeader)
        } footer: {
            Text(L10n.storageGoogleFolderDescription)
        }
        .task { await load() }
    }

    private var isValid: Bool { GoogleDriveStorageLocation(location) != nil }

    private func load() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let value = try await GoogleDriveStorageLocation.load(accountID: accountID)
            try Task.checkCancellation()
            location = value.folderName
            savedLocation = location
            isLoaded = true
            errorMessage = nil
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func save() async {
        guard !isBusy, let value = GoogleDriveStorageLocation(location) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await GoogleDriveStorageLocation.save(value, accountID: accountID)
            location = value.folderName
            savedLocation = location
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

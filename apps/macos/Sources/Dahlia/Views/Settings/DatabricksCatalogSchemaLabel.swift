import SwiftUI

struct DatabricksCatalogSchemaLabel: View {
    let connectionID: UUID
    @State private var value: DatabricksCatalogSchema?
    @State private var isLoaded = false
    @State private var errorMessage: String?
    @State private var revision = 0

    var body: some View {
        Group {
            if let errorMessage {
                SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle", tint: .orange)
            } else if isLoaded {
                Text(value.map { L10n.databricksCatalogSchemaValue($0.description) } ?? L10n.databricksCatalogSchemaUnset)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: revision) {
            do {
                let value = try await DatabricksCatalogSchema.load(connectionID: connectionID)
                try Task.checkCancellation()
                self.value = value
                isLoaded = true
                errorMessage = nil
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProviderAccountSettings.didChange(accountID: connectionID))) { _ in revision += 1 }
    }
}

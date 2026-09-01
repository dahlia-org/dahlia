import SwiftUI

struct VaultAccountPicker: View {
    let vault: VaultRecord
    let connections: [DahliaAccountConnection]
    let onSelect: (UUID?) async -> UUID?

    @State private var selection: UUID?
    @State private var updateTask: Task<Void, Never>?
    @State private var suppressNextChange = false

    init(
        vault: VaultRecord,
        connections: [DahliaAccountConnection],
        onSelect: @escaping (UUID?) async -> UUID?
    ) {
        self.vault = vault
        self.connections = connections
        self.onSelect = onSelect
        _selection = State(initialValue: vault.accountConnectionId)
    }

    var body: some View {
        Picker(L10n.account, selection: $selection) {
            Text(L10n.localAccount).tag(UUID?.none)
            ForEach(connections) { connection in
                Text(accountLabel(connection)).tag(Optional(connection.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(updateTask != nil)
        .onChange(of: selection) { oldValue, newValue in
            if suppressNextChange {
                suppressNextChange = false
                return
            }
            guard oldValue != newValue else { return }
            updateTask = Task {
                let persistedSelection = await onSelect(newValue)
                guard !Task.isCancelled else { return }
                if selection == newValue, persistedSelection != newValue {
                    suppressNextChange = true
                    selection = persistedSelection
                }
                updateTask = nil
            }
        }
        .onChange(of: vault.accountConnectionId) { _, connectionID in
            updateTask?.cancel()
            updateTask = nil
            if selection != connectionID {
                suppressNextChange = true
                selection = connectionID
            }
        }
        .onDisappear {
            updateTask?.cancel()
            updateTask = nil
        }
    }

    private func accountLabel(_ connection: DahliaAccountConnection) -> String {
        "\(connection.displayName) · \(connection.isCloud ? L10n.dahliaCloud : L10n.dahliaServer)"
    }
}

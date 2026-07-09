import SwiftUI

/// Obsidian 風の保管庫登録・選択画面。
struct VaultPickerView: View {
    let appDatabase: AppDatabaseManager?
    let onVaultSelected: (VaultRecord) -> Void

    @State private var vaults: [VaultRecord] = []
    @State private var showFolderPicker = false

    private static var defaultVaultURL: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return documentsURL.appendingPathComponent("Meetings", isDirectory: true)
    }

    private var repository: MeetingRepository? {
        appDatabase.map { MeetingRepository(dbQueue: $0.dbQueue) }
    }

    var body: some View {
        HStack(spacing: 0) {
            vaultList
            Divider()
            mainPanel
        }
        .frame(minWidth: 820, minHeight: 460)
        .task { loadVaults() }
    }

    // MARK: - Left: Vault List

    private var vaultList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(vaults) { vault in
                    VaultRow(vault: vault) {
                        onVaultSelected(vault)
                    }
                    .contextMenu {
                        Button(L10n.removeVault, role: .destructive) {
                            deleteVault(vault)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 260)
    }

    // MARK: - Right: Main Panel

    private var mainPanel: some View {
        VStack(spacing: 32) {
            Spacer()

            // App branding
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("Dahlia")
                    .font(.largeTitle.bold())
            }

            Spacer()

            // Actions
            VStack(spacing: 0) {
                actionRow(
                    title: L10n.openFolderAsVault,
                    description: L10n.openFolderAsVaultDescription
                ) {
                    Button(L10n.open) {
                        showFolderPicker = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(repository == nil)
                }
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                registerVault(url: url)
            }
        }
        .fileDialogDefaultDirectory(Self.defaultVaultURL)
    }

    private func actionRow(
        title: String,
        description: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func loadVaults() {
        vaults = (try? repository?.fetchAllVaults()) ?? []
    }

    private func registerVault(url: URL) {
        guard repository != nil else { return }
        let now = Date()
        let vault = VaultRecord(
            id: .v7(),
            path: url.path,
            name: url.lastPathComponent,
            createdAt: now,
            lastOpenedAt: now
        )
        try? repository?.insertVault(vault)
        loadVaults()
        onVaultSelected(vault)
    }

    private func deleteVault(_ vault: VaultRecord) {
        try? repository?.deleteVault(id: vault.id)
        loadVaults()
    }
}

// MARK: - Vault Row

private struct VaultRow: View {
    let vault: VaultRecord
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vault.name)
                    .font(.headline)
                Text(vault.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
    }
}

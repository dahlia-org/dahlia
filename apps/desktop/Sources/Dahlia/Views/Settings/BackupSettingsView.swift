import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

enum BackupFileFormat {
    static let pathExtension = "sqlite"
    static let contentType = UTType(filenameExtension: pathExtension) ?? .data
}

struct BackupSettingsView: View {
    @State private var model: BackupSettingsViewModel
    @State private var pendingDeleteGeneration: BackupGeneration?
    @State private var pendingRestoreGeneration: BackupGeneration?
    @State private var restoreMode = VaultBackupRestoreRequest.Mode.newVault
    @State private var restoredVaultName = ""

    private let dbQueue: DatabaseQueue?
    private let onShowUnprocessedRecordings: (UUID) -> Void
    @ObservedObject private var captionViewModel: CaptionViewModel
    @ObservedObject private var settings = AppSettings.shared

    init(
        dbQueue: DatabaseQueue?,
        captionViewModel: CaptionViewModel,
        onShowUnprocessedRecordings: @escaping (UUID) -> Void
    ) {
        self.dbQueue = dbQueue
        self.onShowUnprocessedRecordings = onShowUnprocessedRecordings
        _captionViewModel = ObservedObject(wrappedValue: captionViewModel)
        _model = State(initialValue: BackupSettingsViewModel(dbQueue: dbQueue))
    }

    var body: some View {
        Form {
            if !model.preflightItems.isEmpty {
                unresolvedAudioSection
            }

            Section {
                Picker(L10n.vault, selection: $model.selectedVaultId) {
                    ForEach(model.vaults) { vault in
                        Text(vault.name).tag(vault.id as UUID?)
                    }
                }
                .disabled(model.isBusy)
                HStack {
                    Button(L10n.createBackup) {
                        Task { await model.createBackup() }
                    }
                    .buttonStyle(.dahlia(.primary))
                    .disabled(dbQueue == nil || model.selectedVaultId == nil || model.isBusy || !model.preflightItems.isEmpty)

                    Button(L10n.importBackup) {
                        importBackup()
                    }
                    .buttonStyle(.dahlia())
                    .disabled(model.isBusy)

                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let statusMessage = model.statusMessage {
                    SettingsStatusMessage(text: statusMessage, systemImage: "checkmark.circle", tint: .green)
                }
                if let errorMessage = model.errorMessage {
                    SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle", tint: .orange)
                }
            } header: {
                Text(L10n.vaultBackup)
            } footer: {
                Text(L10n.vaultBackupDescription)
            }

            Section(L10n.backupGenerations) {
                if model.generations.isEmpty {
                    ContentUnavailableView(
                        L10n.noBackups,
                        systemImage: "externaldrive.badge.timemachine",
                        description: Text(L10n.noBackupsDescription)
                    )
                } else {
                    ForEach(model.generations) { generation in
                        generationRow(generation)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            model.selectedVaultId = settings.currentVault?.id
            while !Task.isCancelled {
                if !model.isBusy {
                    await model.refresh()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog(
            L10n.deleteBackupConfirmation,
            isPresented: Binding(
                get: { pendingDeleteGeneration != nil },
                set: { if !$0 { pendingDeleteGeneration = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.deleteBackup, role: .destructive) {
                guard let generation = pendingDeleteGeneration else { return }
                pendingDeleteGeneration = nil
                Task { await model.deleteBackup(generation) }
            }
            Button(L10n.cancel, role: .cancel) { pendingDeleteGeneration = nil }
        } message: {
            Text(L10n.deleteBackupDescription)
        }
        .overlay {
            if let generation = pendingRestoreGeneration, let metadata = generation.metadata {
                restoreDialog(generation, metadata: metadata)
            }
        }
    }

    private func restoreDialog(_ generation: BackupGeneration, metadata: BackupMetadata) -> some View {
        let canOverwrite = model.canOverwrite(metadata)
        return ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { if !model.isBusy { pendingRestoreGeneration = nil } }
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.restoreBackupConfirmation).font(.headline)
                Text(restoreMode == .overwrite
                    ? model.vaults.first(where: { $0.id == metadata.vaultId })?.name ?? metadata.vaultName
                    : metadata.vaultName)
                Picker(L10n.backupRestoreMode, selection: $restoreMode) {
                    Text(L10n.backupRestoreAsNewVault).tag(VaultBackupRestoreRequest.Mode.newVault)
                    Text(L10n.backupOverwriteOriginalVault).tag(VaultBackupRestoreRequest.Mode.overwrite)
                        .disabled(!canOverwrite)
                }
                .pickerStyle(.radioGroup)
                if restoreMode == .newVault {
                    TextField(L10n.vaultName, text: $restoredVaultName)
                }
                Text(L10n.vaultBackupRestoreDescription).font(.callout).foregroundStyle(.secondary)
                if !canOverwrite {
                    Text(L10n.backupRestoreTargetUnavailable).font(.callout).foregroundStyle(.secondary)
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button(L10n.cancel) { pendingRestoreGeneration = nil }
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.restoreBackup) {
                        guard captionViewModel.canSwitchVault else { return }
                        let isOverwriting = restoreMode == .overwrite
                        let request = VaultBackupRestoreRequest(
                            sourceVaultId: metadata.vaultId,
                            targetVaultId: isOverwriting ? metadata.vaultId : .v7(),
                            mode: restoreMode, name: isOverwriting ? metadata.vaultName : restoredVaultName
                        )
                        Task {
                            if await model.prepareRestore(generation, request: request) {
                                BackupRelaunchCoordinator.relaunchAfterTermination()
                            }
                        }
                    }
                    .buttonStyle(.dahlia(.primary))
                    .disabled(!captionViewModel.canSwitchVault || model.hasWorkInProgress
                        || (restoreMode == .overwrite && !canOverwrite)
                        || (restoreMode == .newVault && restoredVaultName.nilIfBlank == nil))
                }
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            .disabled(model.isBusy)
            .padding(24)
            .frame(maxWidth: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
            .shadow(radius: 20)
        }
    }

    private var unresolvedAudioSection: some View {
        Section {
            LabeledContent {
                Button(L10n.viewUnprocessedRecordings, systemImage: "arrow.right") {
                    guard let vaultID = unprocessedRecordingsTargetVaultID else { return }
                    onShowUnprocessedRecordings(vaultID)
                }
                .buttonStyle(.dahlia(.primary))
                .disabled(unprocessedRecordingsTargetVaultID == nil)
                .help(unprocessedRecordingsNavigationHelp)
            } label: {
                Label(
                    L10n.resolveUnprocessedRecordings(model.preflightItems.count),
                    systemImage: "waveform.badge.exclamationmark"
                )
            }
        } header: {
            Text(L10n.unprocessedRecordings)
        } footer: {
            Text(L10n.unprocessedRecordingsDescription)
        }
    }

    private var unprocessedRecordingsTargetVaultID: UUID? {
        Self.unprocessedRecordingsTargetVaultID(
            in: model.preflightItems,
            currentVaultID: settings.currentVault?.id,
            canSwitchVault: captionViewModel.canSwitchVault
        )
    }

    private var unprocessedRecordingsNavigationHelp: String {
        unprocessedRecordingsTargetVaultID == nil
            ? L10n.finishRecordingBeforeOpeningAnotherVault
            : L10n.viewUnprocessedRecordings
    }

    nonisolated static func unprocessedRecordingsTargetVaultID(
        in items: [BackupPreflightItem],
        currentVaultID: UUID?,
        canSwitchVault: Bool
    ) -> UUID? {
        if let currentVaultID,
           items.contains(where: { $0.vaultId == currentVaultID }) {
            return currentVaultID
        }
        return canSwitchVault ? items.first?.vaultId : nil
    }

    private func generationRow(_ generation: BackupGeneration) -> some View {
        LabeledContent {
            HStack {
                Button(L10n.exportBackup) { exportBackup(generation) }
                    .buttonStyle(.dahlia())
                    .disabled(!generation.isValid || model.isBusy)
                Button(L10n.restoreBackup) {
                    restoreMode = .newVault
                    restoredVaultName = L10n.restoredVaultName(generation.metadata?.vaultName ?? "")
                    model.errorMessage = nil
                    pendingRestoreGeneration = generation
                }
                .buttonStyle(.dahlia())
                .disabled(
                    !generation.isValid
                        || model.isBusy
                        || !captionViewModel.canSwitchVault
                        || model.hasWorkInProgress
                )
                Button(L10n.delete, role: .destructive) { pendingDeleteGeneration = generation }
                    .buttonStyle(.dahlia(.destructive))
                    .disabled(model.isBusy)
            }
        } label: {
            if let metadata = generation.metadata {
                Text(metadata.vaultName)
                Text(metadata.createdAt.formatted(date: .abbreviated, time: .standard))
                Text(L10n.backupGenerationDetail(
                    schemaVersion: metadata.schemaVersion,
                    appVersion: metadata.appVersion,
                    size: ByteCountFormatter.string(fromByteCount: generation.fileSize, countStyle: .file)
                ))
                if metadata.reason == .beforeRestore {
                    Text(L10n.beforeRestoreBackup)
                }
            } else {
                Text(generation.fileURL.lastPathComponent)
                Text(generation.validationError ?? L10n.invalidBackup)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [BackupFileFormat.contentType]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let isAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if isAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                await model.importBackup(from: url)
            }
        }
    }

    private func exportBackup(_ generation: BackupGeneration) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [BackupFileFormat.contentType]
        panel.nameFieldStringValue = generation.fileURL.lastPathComponent
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let isAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if isAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                await model.exportBackup(generation, to: url)
            }
        }
    }
}

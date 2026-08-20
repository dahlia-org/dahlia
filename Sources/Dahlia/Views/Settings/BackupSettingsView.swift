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

    private let dbQueue: DatabaseQueue?
    private let onShowUnprocessedRecordings: (UUID) -> Void
    @ObservedObject private var captionViewModel: CaptionViewModel

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
                HStack {
                    Button(L10n.createBackup) {
                        Task { await model.createBackup() }
                    }
                    .buttonStyle(.dahlia(.primary))
                    .disabled(dbQueue == nil || model.isBusy || !model.preflightItems.isEmpty)

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
                Text(L10n.databaseBackup)
            } footer: {
                Text(L10n.databaseBackupDescription)
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
        .confirmationDialog(
            L10n.restoreBackupConfirmation,
            isPresented: Binding(
                get: { pendingRestoreGeneration != nil },
                set: { if !$0 { pendingRestoreGeneration = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.restoreBackup, role: .destructive) {
                guard let generation = pendingRestoreGeneration,
                      !captionViewModel.isListening else { return }
                pendingRestoreGeneration = nil
                Task {
                    if await model.prepareRestore(generation) {
                        BackupRelaunchCoordinator.relaunchAfterTermination()
                    }
                }
            }
            Button(L10n.cancel, role: .cancel) { pendingRestoreGeneration = nil }
        } message: {
            Text(L10n.restoreBackupDescription)
        }
    }

    private var unresolvedAudioSection: some View {
        Section {
            LabeledContent {
                Button(L10n.viewUnprocessedRecordings, systemImage: "arrow.right") {
                    guard let vaultID = model.preflightItems.first?.vaultId else { return }
                    onShowUnprocessedRecordings(vaultID)
                }
                .buttonStyle(.dahlia(.primary))
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

    private func generationRow(_ generation: BackupGeneration) -> some View {
        LabeledContent {
            HStack {
                Button(L10n.exportBackup) { exportBackup(generation) }
                    .buttonStyle(.dahlia())
                    .disabled(!generation.isValid || model.isBusy)
                Button(L10n.restoreBackup) { pendingRestoreGeneration = generation }
                    .buttonStyle(.dahlia())
                    .disabled(
                        !generation.isValid
                            || model.isBusy
                            || captionViewModel.isListening
                            || !model.preflightItems.isEmpty
                    )
                Button(L10n.delete, role: .destructive) { pendingDeleteGeneration = generation }
                    .buttonStyle(.dahlia(.destructive))
                    .disabled(model.isBusy)
            }
        } label: {
            if let metadata = generation.metadata {
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

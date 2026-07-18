import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @State private var model: BackupSettingsViewModel
    @State private var pendingDeleteGeneration: BackupGeneration?
    @State private var pendingRestoreGeneration: BackupGeneration?
    @State private var pendingDiscardItem: BackupPreflightItem?

    private let dbQueue: DatabaseQueue?
    @ObservedObject private var captionViewModel: CaptionViewModel
    private let sidebarViewModel: SidebarViewModel

    init(
        dbQueue: DatabaseQueue?,
        captionViewModel: CaptionViewModel,
        sidebarViewModel: SidebarViewModel
    ) {
        self.dbQueue = dbQueue
        _captionViewModel = ObservedObject(wrappedValue: captionViewModel)
        self.sidebarViewModel = sidebarViewModel
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
                    .buttonStyle(.borderedProminent)
                    .disabled(dbQueue == nil || model.isBusy || !model.preflightItems.isEmpty)

                    Button(L10n.importBackup) {
                        importBackup()
                    }
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
        .confirmationDialog(
            L10n.discardUnprocessedRecordingConfirmation,
            isPresented: Binding(
                get: { pendingDiscardItem != nil },
                set: { if !$0 { pendingDiscardItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.discardRecording, role: .destructive) {
                guard let item = pendingDiscardItem else { return }
                pendingDiscardItem = nil
                Task { await model.discardAudio(item) }
            }
            Button(L10n.cancel, role: .cancel) { pendingDiscardItem = nil }
        } message: {
            Text(L10n.discardUnprocessedRecordingDescription)
        }
    }

    private var unresolvedAudioSection: some View {
        Section {
            ForEach(model.preflightItems) { item in
                LabeledContent {
                    HStack {
                        if item.state == .awaitingConfirmation || item.state == .failed {
                            Button(L10n.transcribe) {
                                resolveByTranscribing(item)
                            }
                            Button(L10n.discardRecording, role: .destructive) {
                                pendingDiscardItem = item
                            }
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } label: {
                    Text(item.meetingName)
                    Text(item.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(preflightStateLabel(item))
                }
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
                    .disabled(!generation.isValid || model.isBusy)
                Button(L10n.restoreBackup) { pendingRestoreGeneration = generation }
                    .disabled(
                        !generation.isValid
                            || model.isBusy
                            || captionViewModel.isListening
                            || !model.preflightItems.isEmpty
                    )
                Button(L10n.delete, role: .destructive) { pendingDeleteGeneration = generation }
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

    private func preflightStateLabel(_ item: BackupPreflightItem) -> String {
        switch item.state {
        case .recording: L10n.recordingInProgress
        case .awaitingConfirmation: L10n.awaitingTranscription
        case .processing: L10n.transcriptionInProgress
        case .failed: item.failureMessage ?? L10n.transcriptionFailed
        }
    }

    private func resolveByTranscribing(_ item: BackupPreflightItem) {
        guard let dbQueue else { return }
        sidebarViewModel.selectMeeting(item.meetingId)
        MainWindowOpener.shared.openMainWindow()
        switch item.state {
        case .awaitingConfirmation:
            captionViewModel.presentBatchTranscriptionConfirmation(
                sessionId: item.sessionId,
                meetingId: item.meetingId,
                dbQueue: dbQueue
            )
        case .failed:
            captionViewModel.retryBatchTranscription(sessionId: item.sessionId, meetingId: item.meetingId)
        case .recording, .processing:
            break
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.database]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.importBackup(from: url) }
        }
    }

    private func exportBackup(_ generation: BackupGeneration) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.database]
        panel.nameFieldStringValue = generation.fileURL.lastPathComponent
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.exportBackup(generation, to: url) }
        }
    }
}

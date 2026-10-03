import AppKit
import DahliaRuntimeSupport
import GRDB
import SwiftUI
import UniformTypeIdentifiers

enum BackupFileFormat {
    static let pathExtension = BackupArchive.pathExtension
    static let contentType = UTType(filenameExtension: pathExtension) ?? .data
}

struct BackupSettingsView: View {
    @State private var model: BackupSettingsViewModel
    @State private var pendingDeleteGeneration: BackupGeneration?
    @State private var pendingRestoreGeneration: BackupGeneration?

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
                HStack {
                    Button(L10n.selectAll) { model.selectedWorkspaceIds = Set(model.workspaces.map(\.id)) }
                        .buttonStyle(.dahlia())
                    Button(L10n.backupDeselectAll) { model.selectedWorkspaceIds.removeAll() }
                        .buttonStyle(.dahlia())
                }
                .disabled(model.isBusy || model.workspaces.isEmpty)
                ForEach(model.workspaces) { workspace in
                    Toggle(isOn: Binding(
                        get: { model.selectedWorkspaceIds.contains(workspace.id) },
                        set: { selected in
                            if selected {
                                model.selectedWorkspaceIds.insert(workspace.id)
                            } else {
                                model.selectedWorkspaceIds.remove(workspace.id)
                            }
                        }
                    )) {
                        Text(workspace.name)
                        Text(TypeID.encode(workspace.id, as: .workspace)).font(.caption).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(model.isBusy)
                }
                HStack {
                    Button(L10n.createBackup) {
                        Task { await model.createBackup() }
                    }
                    .buttonStyle(.dahlia(.primary))
                    .disabled(dbQueue == nil || model.selectedWorkspaceIds.isEmpty || model.isBusy || !model.preflightItems.isEmpty)

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
                Text(L10n.workspaceBackup)
            } footer: {
                Text(L10n.workspaceBackupDescription + "\n" + L10n.backupLocalWorkspacesOnly)
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
            model.selectedWorkspaceIds = Set([settings.currentWorkspace?.id].compactMap(\.self))
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
            if let generation = pendingRestoreGeneration {
                restoreDialog(generation)
            }
        }
    }

    private func restoreDialog(_ generation: BackupGeneration) -> some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { if !model.isBusy { pendingRestoreGeneration = nil } }
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.restoreBackupConfirmation).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach($model.restoreSelections) { $selection in
                            restoreRow($selection)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
                Text(L10n.workspaceBackupRestoreDescription).font(.callout).foregroundStyle(.secondary)
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button(L10n.cancel) { pendingRestoreGeneration = nil }
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.restoreBackup) {
                        Task {
                            guard captionViewModel.canSwitchWorkspace else { return }
                            if await model.prepareRestore(generation) {
                                BackupRelaunchCoordinator.relaunchAfterTermination()
                            }
                        }
                    }
                    .buttonStyle(.dahlia(.primary))
                    .disabled(!captionViewModel.canSwitchWorkspace || !model.canRestore)
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

    private func restoreRow(_ selection: Binding<BackupRestoreSelection>) -> some View {
        let workspace = selection.wrappedValue.workspace
        let canOverwrite = model.canOverwrite(workspaceId: workspace.id)
        return VStack(alignment: .leading, spacing: 8) {
            Text(workspace.name).font(.headline)
            Text(TypeID.encode(workspace.id, as: .workspace)).font(.caption).foregroundStyle(.secondary)
            Picker(L10n.backupRestoreMode, selection: selection.mode) {
                Text(L10n.backupSkipWorkspace).tag(nil as WorkspaceBackupRestoreRequest.Mode?)
                Text(L10n.backupOverwriteOriginalWorkspace).tag(WorkspaceBackupRestoreRequest.Mode.overwrite as WorkspaceBackupRestoreRequest.Mode?)
                    .disabled(!canOverwrite)
                Text(L10n.backupRestoreAsNewWorkspace).tag(WorkspaceBackupRestoreRequest.Mode.newWorkspace as WorkspaceBackupRestoreRequest.Mode?)
            }
            if selection.wrappedValue.mode == .newWorkspace {
                TextField(L10n.workspaceName, text: selection.name)
            }
            if !canOverwrite {
                Text(L10n.backupRestoreTargetUnavailable).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var unresolvedAudioSection: some View {
        Section {
            LabeledContent {
                Button(L10n.viewUnprocessedRecordings, systemImage: "arrow.right") {
                    guard let workspaceID = unprocessedRecordingsTargetWorkspaceID else { return }
                    onShowUnprocessedRecordings(workspaceID)
                }
                .buttonStyle(.dahlia(.primary))
                .disabled(unprocessedRecordingsTargetWorkspaceID == nil)
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

    private var unprocessedRecordingsTargetWorkspaceID: UUID? {
        Self.unprocessedRecordingsTargetWorkspaceID(
            in: model.preflightItems,
            currentWorkspaceID: settings.currentWorkspace?.id,
            canSwitchWorkspace: captionViewModel.canSwitchWorkspace
        )
    }

    private var unprocessedRecordingsNavigationHelp: String {
        unprocessedRecordingsTargetWorkspaceID == nil
            ? L10n.finishRecordingBeforeOpeningAnotherWorkspace
            : L10n.viewUnprocessedRecordings
    }

    nonisolated static func unprocessedRecordingsTargetWorkspaceID(
        in items: [BackupPreflightItem],
        currentWorkspaceID: UUID?,
        canSwitchWorkspace: Bool
    ) -> UUID? {
        if let currentWorkspaceID,
           items.contains(where: { $0.workspaceId == currentWorkspaceID }) {
            return currentWorkspaceID
        }
        return canSwitchWorkspace ? items.first?.workspaceId : nil
    }

    private func generationRow(_ generation: BackupGeneration) -> some View {
        LabeledContent {
            HStack {
                Button(L10n.exportBackup) { exportBackup(generation) }
                    .buttonStyle(.dahlia())
                    .disabled(!generation.isValid || model.isBusy)
                Button(L10n.restoreBackup) {
                    guard let metadata = generation.metadata else { return }
                    model.beginRestore(metadata)
                    pendingRestoreGeneration = generation
                }
                .buttonStyle(.dahlia())
                .disabled(
                    !generation.isValid
                        || model.isBusy
                        || !captionViewModel.canSwitchWorkspace
                        || model.hasWorkInProgress
                )
                Button(L10n.delete, role: .destructive) { pendingDeleteGeneration = generation }
                    .buttonStyle(.dahlia(.destructive))
                    .disabled(model.isBusy)
            }
        } label: {
            if let metadata = generation.metadata {
                Text(L10n.backupWorkspaceCount(metadata.workspaces.count))
                Text(metadata.workspaces.map(\.name).joined(separator: ", ")).lineLimit(2)
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

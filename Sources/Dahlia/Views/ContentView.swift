import SwiftUI

/// ミーティング一覧サイドバーと詳細ビューを構成するルートビュー。
struct ContentView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
    var onSelectVault: (VaultRecord) -> Void = { _ in }

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            MeetingListSidebarView(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                recordingCoordinator: recordingCoordinator
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            detailView
                .navigationTitle("")
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    recordingCoordinator.createEmptyMeeting()
                } label: {
                    Label(L10n.newMeeting, systemImage: "square.and.pencil")
                }
                .labelStyle(.iconOnly)
                .help(L10n.newMeeting)

                Button(action: returnToCalendarSchedule) {
                    Label(L10n.showUpcomingSchedule, systemImage: "calendar")
                }
                .labelStyle(.iconOnly)
                .help(L10n.showUpcomingSchedule)

                Button {
                    openWindow(id: WindowID.projectManager)
                } label: {
                    Label(L10n.manageProjects, systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .help(L10n.manageProjects)

                SettingsLink {
                    Label(L10n.settingsMenuItem, systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)
                .help(L10n.settingsMenuItem)
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(item: $viewModel.pendingBatchTranscriptionConfirmation) { confirmation in
            BatchTranscriptionConfirmationView(
                locales: viewModel.batchTranscriptionLocaleOptions(
                    preferredIdentifier: confirmation.suggestedLocaleIdentifier
                ),
                initialLocaleIdentifier: confirmation.suggestedLocaleIdentifier,
                initiallyRetainsAudioAfterBatch: confirmation.retainAudioAfterBatch,
                initiallyGeneratesSummaryAfterTranscription: confirmation.generateSummaryAfterTranscription,
                onStart: viewModel.confirmBatchTranscription,
                onPostpone: viewModel.postponeBatchTranscription
            )
            .interactiveDismissDisabled()
        }
        .onChange(of: sidebarViewModel.selectedMeetingIds) { oldValue, newValue in
            guard oldValue != newValue else { return }
            handleMeetingSelectionChange(newValue)
        }
        .onChange(of: viewModel.currentMeetingId) { oldId, newId in
            guard oldId != newId, let newId else { return }
            if sidebarViewModel.selectedMeetingId != newId {
                sidebarViewModel.selectMeeting(newId)
            }
        }
        .onChange(of: sidebarViewModel.currentVault?.id) { _, _ in
            sidebarViewModel.clearMeetingSelection()
            viewModel.clearCurrentMeeting()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if sidebarViewModel.selectedMeetingIds.count > 1 {
            MultipleMeetingSelectionView(sidebarViewModel: sidebarViewModel)
        } else if sidebarViewModel.selectedMeetingId != nil || viewModel.hasDraftMeeting || viewModel.currentMeetingId != nil {
            ControlPanelView(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                recordingCoordinator: recordingCoordinator
            )
        } else {
            CalendarScheduleView(
                onSelectEvent: handleCalendarEventSelection,
                onCreateMeeting: recordingCoordinator.createEmptyMeeting
            )
        }
    }

    private func handleMeetingSelectionChange(_ selection: Set<UUID>) {
        guard selection.count == 1, let meetingId = selection.first else {
            if !selection.isEmpty || !viewModel.hasDraftMeeting {
                viewModel.clearCurrentMeeting()
            }
            return
        }
        handleMeetingSelection(meetingId)
    }

    private func returnToCalendarSchedule() {
        if viewModel.hasDraftMeeting || sidebarViewModel.selectedMeetingIds.isEmpty {
            viewModel.clearCurrentMeeting()
        }
        sidebarViewModel.clearMeetingSelection()
    }

    private func handleCalendarEventSelection(_ event: CalendarEvent) {
        guard let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else { return }

        let repository = MeetingRepository(dbQueue: dbQueue)
        do {
            if let existingMeetingId = try repository.resolveMeetingIdForCalendarEvent(event, vaultId: vault.id) {
                sidebarViewModel.selectMeeting(existingMeetingId)
                return
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
            return
        }

        sidebarViewModel.clearMeetingSelection()
        viewModel.beginDraftMeeting(
            from: event,
            dbQueue: dbQueue,
            vaultURL: vault.url
        )
    }

    private func handleMeetingSelection(_ meetingId: UUID) {
        guard let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else { return }

        do {
            let repository = MeetingRepository(dbQueue: dbQueue)
            guard let meeting = try repository.fetchMeeting(id: meetingId) else { return }
            let project = try meeting.projectId.flatMap { try repository.fetchProject(id: $0) }
            viewModel.loadMeeting(
                meetingId,
                dbQueue: dbQueue,
                projectURL: project.map { vault.url.appending(path: $0.name, directoryHint: .isDirectory) },
                projectId: project?.id,
                projectName: project?.name,
                vaultURL: vault.url
            )
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

private struct MultipleMeetingSelectionView: View {
    var sidebarViewModel: SidebarViewModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checklist")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)

            Text(L10n.selectedCount(sidebarViewModel.selectedMeetingIds.count))
                .font(.title2.weight(.semibold))

            HStack(spacing: 10) {
                Menu {
                    Button(L10n.noProject) {
                        sidebarViewModel.moveMeetings(ids: sidebarViewModel.selectedMeetingIds, toProjectId: nil)
                    }

                    Divider()

                    ForEach(sidebarViewModel.allProjectItems) { project in
                        Button(project.projectName) {
                            sidebarViewModel.moveMeetings(
                                ids: sidebarViewModel.selectedMeetingIds,
                                toProjectId: project.projectId
                            )
                        }
                    }
                } label: {
                    Label(L10n.moveToProject, systemImage: "folder")
                }

                Button(role: .destructive) {
                    sidebarViewModel.deleteMeetings(ids: sidebarViewModel.selectedMeetingIds)
                } label: {
                    Label(L10n.deleteCount(sidebarViewModel.selectedMeetingIds.count), systemImage: "trash")
                }

                Button(L10n.clear) {
                    sidebarViewModel.clearMeetingSelection()
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

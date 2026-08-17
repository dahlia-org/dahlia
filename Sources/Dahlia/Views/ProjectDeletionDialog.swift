import SwiftUI

struct ProjectDeletionDialog: View {
    let project: ProjectOverviewItem
    let projectCount: Int
    let meetingCount: Int
    let moveDestinations: [ProjectOverviewItem]
    let onCancel: () -> Void
    let onConfirm: (ProjectMeetingDisposition, Bool) async -> String?

    @State private var deletesMeetings: Bool
    @State private var selectedDestinationId: UUID?
    @State private var deletesSummaryFiles = false
    @State private var isDeleting = false
    @State private var deletionErrorMessage: String?

    init(
        project: ProjectOverviewItem,
        projectCount: Int,
        meetingCount: Int,
        moveDestinations: [ProjectOverviewItem],
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (ProjectMeetingDisposition, Bool) async -> String?
    ) {
        self.project = project
        self.projectCount = projectCount
        self.meetingCount = meetingCount
        self.moveDestinations = moveDestinations
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _deletesMeetings = State(initialValue: moveDestinations.isEmpty)
        _selectedDestinationId = State(initialValue: moveDestinations.first?.projectId)
    }

    var body: some View {
        ZStack {
            Button(action: cancel) {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 20) {
                ProjectEditorSheetHeader(
                    title: L10n.deleteProjectConfirmation(project.projectName),
                    isDisabled: isDeleting,
                    onClose: cancel
                )

                Form {
                    Section {
                        Label {
                            Text(project.projectName)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "folder")
                        }

                        Label(
                            L10n.projectDeletionSummary(projectCount: projectCount, meetingCount: meetingCount),
                            systemImage: "trash"
                        )

                        Text(L10n.projectDirectoriesAreKept)
                            .foregroundStyle(.secondary)

                        if meetingCount > 0 {
                            Label(deletionImpactDescription, systemImage: deletionImpactSystemImage)
                                .foregroundStyle(deletesMeetings ? .red : .secondary)
                        }
                    }

                    if meetingCount > 0 {
                        Section(L10n.meetingHandling) {
                            Picker(L10n.meetingHandling, selection: $deletesMeetings) {
                                if !moveDestinations.isEmpty {
                                    Text(L10n.moveMeetingsBeforeDeletingProject)
                                        .tag(false)
                                }
                                Text(L10n.deleteMeetingsWithProject)
                                    .tag(true)
                            }
                            .pickerStyle(.radioGroup)

                            if !deletesMeetings, !moveDestinations.isEmpty {
                                Picker(L10n.moveMeetingsTo, selection: $selectedDestinationId) {
                                    ForEach(moveDestinations) { destination in
                                        Text(destination.projectName)
                                            .tag(destination.projectId as UUID?)
                                    }
                                }
                            } else if moveDestinations.isEmpty {
                                Label(L10n.noProjectMoveDestination, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            }

                            if deletesMeetings {
                                Toggle(L10n.deleteExportedSummaries, isOn: $deletesSummaryFiles)
                                Text(L10n.deleteExportedSummariesHelp)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(isDeleting)

                if let deletionErrorMessage {
                    SettingsStatusMessage(
                        text: deletionErrorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                    .accessibilityLabel("\(L10n.projectOperationFailed): \(deletionErrorMessage)")
                }

                HStack(spacing: 12) {
                    Spacer()

                    Button(role: .cancel, action: cancel) {
                        Text(L10n.cancel)
                            .frame(minWidth: 72)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDeleting)

                    Button(role: .destructive, action: confirmDeletion) {
                        HStack {
                            if isDeleting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isDeleting ? L10n.deletingProjects : confirmButtonTitle)
                        }
                        .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .tint(.red)
                    .controlSize(.extraLarge)
                    .disabled(!canConfirmDeletion)
                }
            }
            .padding(24)
            .frame(width: 560, height: dialogHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: 14))
            .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
        }
        .transition(.identity)
    }

    private var dialogHeight: CGFloat {
        meetingCount > 0 ? 480 : 400
    }

    private var confirmButtonTitle: String {
        if meetingCount == 0 {
            L10n.deleteProject
        } else if deletesMeetings {
            L10n.deleteProjectAndMeetings
        } else {
            L10n.moveAndDeleteProject
        }
    }

    private var canConfirmDeletion: Bool {
        !isDeleting && Self.meetingDisposition(
            meetingCount: meetingCount,
            deletesMeetings: deletesMeetings,
            selectedDestinationId: selectedDestinationId
        ) != nil
    }

    private var deletionImpactDescription: String {
        if deletesMeetings {
            L10n.projectMeetingsWillBeDeleted(meetingCount)
        } else if let selectedDestinationName {
            L10n.projectMeetingsWillBeMoved(count: meetingCount, destination: selectedDestinationName)
        } else {
            L10n.noProjectMoveDestination
        }
    }

    private var deletionImpactSystemImage: String {
        deletesMeetings ? "exclamationmark.triangle.fill" : "arrow.right.circle"
    }

    private var selectedDestinationName: String? {
        guard let selectedDestinationId else { return nil }
        return moveDestinations.first(where: { $0.projectId == selectedDestinationId })?.projectName
    }

    private func confirmDeletion() {
        guard let disposition = Self.meetingDisposition(
            meetingCount: meetingCount,
            deletesMeetings: deletesMeetings,
            selectedDestinationId: selectedDestinationId
        ) else { return }

        deletionErrorMessage = nil
        isDeleting = true
        Task {
            if let errorMessage = await onConfirm(disposition, deletesMeetings && deletesSummaryFiles) {
                deletionErrorMessage = errorMessage
                isDeleting = false
            } else {
                onCancel()
            }
        }
    }

    private func cancel() {
        guard !isDeleting else { return }
        onCancel()
    }

    static func meetingDisposition(
        meetingCount: Int,
        deletesMeetings: Bool,
        selectedDestinationId: UUID?
    ) -> ProjectMeetingDisposition? {
        if meetingCount == 0 || deletesMeetings {
            .deleteMeetings
        } else if let selectedDestinationId {
            .move(to: selectedDestinationId)
        } else {
            nil
        }
    }
}

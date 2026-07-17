import SwiftUI

struct ProjectDeletionDialog: View {
    let project: ProjectOverviewItem
    let projectCount: Int
    let meetingCount: Int
    let moveDestinations: [ProjectOverviewItem]
    let onConfirm: (ProjectMeetingDisposition) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var deletesMeetings: Bool
    @State private var selectedDestinationId: UUID?
    @State private var isDeleting = false
    @State private var deletionErrorMessage: String?

    init(
        project: ProjectOverviewItem,
        projectCount: Int,
        meetingCount: Int,
        moveDestinations: [ProjectOverviewItem],
        onConfirm: @escaping (ProjectMeetingDisposition) async -> String?
    ) {
        self.project = project
        self.projectCount = projectCount
        self.meetingCount = meetingCount
        self.moveDestinations = moveDestinations
        self.onConfirm = onConfirm
        _deletesMeetings = State(initialValue: moveDestinations.isEmpty)
        _selectedDestinationId = State(initialValue: moveDestinations.first?.projectId)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.deleteProjectConfirmation(project.projectName))
                .font(.title2)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.top, .horizontal])
                .accessibilityAddTraits(.isHeader)

            Form {
                Section {
                    Label(
                        L10n.projectDeletionSummary(projectCount: projectCount, meetingCount: meetingCount),
                        systemImage: "trash"
                    )

                    Text(L10n.projectFoldersMoveToTrash)
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
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isDeleting)

            if let deletionErrorMessage {
                Label(deletionErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .accessibilityLabel("\(L10n.projectOperationFailed): \(deletionErrorMessage)")
            }

            Divider()

            HStack {
                if isDeleting {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.deletingProjects)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Button(L10n.cancel, role: .cancel, action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDeleting)
                Button(confirmButtonTitle, role: .destructive, action: confirmDeletion)
                    .disabled(!canConfirmDeletion)
            }
            .padding()
        }
        .navigationTitle(L10n.deleteProjectConfirmation(project.projectName))
        .frame(minWidth: 520, minHeight: 390)
        .interactiveDismissDisabled(isDeleting)
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
            if let errorMessage = await onConfirm(disposition) {
                deletionErrorMessage = errorMessage
                isDeleting = false
            } else {
                dismiss()
            }
        }
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

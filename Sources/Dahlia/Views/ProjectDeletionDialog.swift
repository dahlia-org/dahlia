import SwiftUI

struct ProjectDeletionDialog: View {
    let project: ProjectOverviewItem
    let projectCount: Int
    let meetingCount: Int
    let moveDestinations: [ProjectOverviewItem]
    let onConfirm: (ProjectMeetingDisposition) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var deletesMeetings: Bool
    @State private var selectedDestinationId: UUID?
    @State private var isDeleting = false

    init(
        project: ProjectOverviewItem,
        projectCount: Int,
        meetingCount: Int,
        moveDestinations: [ProjectOverviewItem],
        onConfirm: @escaping (ProjectMeetingDisposition) async -> Bool
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
            Form {
                Section {
                    Label(
                        L10n.projectDeletionSummary(projectCount: projectCount, meetingCount: meetingCount),
                        systemImage: "trash"
                    )
                    Text(L10n.deleteProjectHelp)
                        .foregroundStyle(.secondary)
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

            Divider()

            HStack {
                Spacer()
                Button(L10n.cancel, role: .cancel, action: dismiss.callAsFunction)
                Button(confirmButtonTitle, role: .destructive, action: confirmDeletion)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isDeleting)
            }
            .padding()
        }
        .navigationTitle(L10n.deleteProjectConfirmation(project.projectName))
        .frame(minWidth: 520, minHeight: 390)
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

    private func confirmDeletion() {
        let disposition: ProjectMeetingDisposition
        if meetingCount == 0 || deletesMeetings {
            disposition = .deleteMeetings
        } else if let selectedDestinationId {
            disposition = .move(to: selectedDestinationId)
        } else {
            return
        }

        isDeleting = true
        Task {
            if await onConfirm(disposition) {
                dismiss()
            } else {
                isDeleting = false
            }
        }
    }
}

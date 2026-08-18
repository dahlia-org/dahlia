import SwiftUI

// MARK: - Project Picker

struct MeetingProjectPicker: View {
    enum Style {
        case regular
        case compact
    }

    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    var style: Style = .regular

    @State private var showProjectPopover = false
    @State private var projectInput = ""
    @FocusState private var isProjectFieldFocused: Bool
    @FocusState private var isRemoveFocused: Bool
    @State private var isHovered = false

    private var hasProjectAssignment: Bool {
        viewModel.currentProjectId != nil
    }

    private var showsRemoveButton: Bool {
        hasProjectAssignment && (isHovered || isRemoveFocused)
    }

    private var trimmedProjectInput: String {
        projectInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentProjectName: String? {
        guard let projectId = viewModel.currentProjectId else { return nil }
        return sidebarViewModel.flatProjects.first(where: { $0.id == projectId })?.name
    }

    private var filteredProjects: [FlatProjectRow] {
        guard !trimmedProjectInput.isEmpty else { return sidebarViewModel.flatProjects }
        return sidebarViewModel.flatProjects.filter { project in
            project.name.localizedStandardContains(trimmedProjectInput)
                || project.displayName.localizedStandardContains(trimmedProjectInput)
        }
    }

    private var shouldShowCreateSuggestion: Bool {
        !trimmedProjectInput.isEmpty
            && !filteredProjects.contains(where: {
                $0.name.caseInsensitiveCompare(trimmedProjectInput) == .orderedSame
            })
    }

    private var emptyProjectMessage: String {
        sidebarViewModel.flatProjects.isEmpty && trimmedProjectInput.isEmpty ? L10n.noProjectsYet : L10n.noResultsFound
    }

    var body: some View {
        HStack(spacing: style == .compact ? 3 : 4) {
            ZStack {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .opacity(showsRemoveButton ? 0 : 1)

                if hasProjectAssignment {
                    Button(action: clearProject) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, minHeight: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($isRemoveFocused)
                    .opacity(showsRemoveButton ? 1 : 0)
                    .allowsHitTesting(showsRemoveButton)
                    .accessibilityLabel(L10n.removeProjectAssignment)
                }
            }
            .frame(width: 16, height: 16)

            projectSelectionButton
        }
        .foregroundStyle(.secondary)
        .dahliaChipSurface(isHovered: isHovered)
        .contentShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .pointerStyle(.link)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            if hasProjectAssignment {
                Button(L10n.removeProjectAssignment, role: .destructive, action: clearProject)
            }
        }
        .popover(isPresented: $showProjectPopover, arrowEdge: .bottom) {
            projectPopoverContent
        }
        .help(currentProjectName ?? L10n.noProject)
    }

    @ViewBuilder
    private var projectSelectionButton: some View {
        let button = Button(action: presentProjectPopover) {
            HStack(spacing: 4) {
                if style == .regular {
                    Text(currentProjectName ?? L10n.noProject)
                        .dahliaFont(.metadata, weight: .medium)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
        }
        .buttonStyle(.plain)

        if hasProjectAssignment {
            button.accessibilityAction(named: Text(L10n.removeProjectAssignment), clearProject)
        } else {
            button
        }
    }

    private func presentProjectPopover() {
        projectInput = ""
        showProjectPopover.toggle()
    }

    private var projectPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(L10n.searchOrCreateProject, text: $projectInput)
                .textFieldStyle(.plain)
                .padding(10)
                .focused($isProjectFieldFocused)
                .onSubmit {
                    submitProjectInput()
                }

            Divider()

            if !filteredProjects.isEmpty || shouldShowCreateSuggestion {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        popoverRow(
                            icon: "minus.circle",
                            name: L10n.noProject,
                            isSelected: viewModel.currentProjectId == nil,
                            action: clearProject
                        )

                        ForEach(filteredProjects, id: \.id) { project in
                            popoverRow(
                                icon: "folder",
                                name: project.name,
                                isSelected: project.id == viewModel.currentProjectId
                            ) {
                                assignMeeting(to: project.id, projectName: project.name)
                            }
                        }

                        if shouldShowCreateSuggestion {
                            popoverRow(icon: "plus", name: trimmedProjectInput) {
                                createAndAssignProject(named: trimmedProjectInput)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            } else {
                VStack {
                    Spacer()
                    Text(emptyProjectMessage)
                        .dahliaFont(.body)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            }
        }
        .frame(width: 280)
        .onAppear {
            isProjectFieldFocused = true
        }
    }

    private func popoverRow(
        icon: String,
        name: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.secondary)

                Text(name)
                    .dahliaFont(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
    }

    private func submitProjectInput() {
        guard !trimmedProjectInput.isEmpty else { return }

        if let matchingProject = sidebarViewModel.flatProjects.first(where: {
            $0.name.caseInsensitiveCompare(trimmedProjectInput) == .orderedSame
        }) {
            assignMeeting(to: matchingProject.id, projectName: matchingProject.name)
            return
        }

        createAndAssignProject(named: trimmedProjectInput)
    }

    private func createAndAssignProject(named name: String) {
        guard let project = sidebarViewModel.fetchOrCreateProject(name: name) else { return }
        assignMeeting(to: project.record.id, projectName: project.record.path)
    }

    private func clearProject() {
        let existingMeetingId = viewModel.currentMeetingId
        let removesPersistedProject = viewModel.currentProjectId != nil
        if removesPersistedProject, let existingMeetingId {
            guard sidebarViewModel.moveMeeting(id: existingMeetingId, toProjectId: nil) else { return }
            sidebarViewModel.selectMeeting(existingMeetingId)
        }
        viewModel.setExplicitProjectContext(projectURL: nil, projectId: nil, projectName: nil)
        projectInput = ""
        showProjectPopover = false
    }

    private func assignMeeting(to projectId: UUID, projectName: String) {
        let projectURL = sidebarViewModel.projectURL(for: projectName)
        guard let meetingId = viewModel.materializeDraftMeeting(
            projectURL: projectURL,
            projectId: projectId,
            projectName: projectName,
            customerIntelligenceIngestion: .afterMeetingPersistence
        ) else { return }

        if projectId != viewModel.currentProjectId,
           !sidebarViewModel.moveMeeting(id: meetingId, toProjectId: projectId) {
            return
        }
        viewModel.setExplicitProjectContext(
            projectURL: projectURL,
            projectId: projectId,
            projectName: projectName
        )
        sidebarViewModel.selectMeeting(meetingId)
        projectInput = ""
        showProjectPopover = false
    }
}

import SwiftUI

/// ミーティング詳細ヘッダーの下に配置するメタデータバー。
/// タグチップ群を横並びで表示する。
struct MeetingMetadataBar: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel

    private var tags: [TagInfo] {
        guard let meetingId = viewModel.currentMeetingId,
              let item = sidebarViewModel.allMeetings.first(where: { $0.meetingId == meetingId }) else { return [] }
        return item.tags
    }

    var body: some View {
        MeetingTagsView(viewModel: viewModel, tags: tags, sidebarViewModel: sidebarViewModel)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tag Management

private struct MeetingTagsView: View {
    @ObservedObject var viewModel: CaptionViewModel
    let tags: [TagInfo]
    var sidebarViewModel: SidebarViewModel

    @State private var showTagPopover = false
    @State private var tagInput = ""

    private var trimmedTagInput: String {
        tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestions: [TagInfo] {
        let existingNames = Set(tags.map(\.name))
        let availableTags = sidebarViewModel.allAvailableTags.filter { !existingNames.contains($0.name) }
        guard !trimmedTagInput.isEmpty else { return availableTags }
        let query = trimmedTagInput.localizedLowercase
        return availableTags.filter { $0.name.localizedLowercase.contains(query) }
    }

    private var shouldShowCreateSuggestion: Bool {
        !trimmedTagInput.isEmpty
            && !tags.contains(where: { $0.name.caseInsensitiveCompare(trimmedTagInput) == .orderedSame })
            && !suggestions.contains(where: { $0.name.caseInsensitiveCompare(trimmedTagInput) == .orderedSame })
    }

    var body: some View {
        FlowLayout(spacing: 6, rowSpacing: 7) {
            ForEach(tags, id: \.name) { tag in
                TagChip(tag: tag) {
                    guard let meetingId = viewModel.currentMeetingId else { return }
                    sidebarViewModel.removeTagFromMeeting(id: meetingId, tag: tag.name)
                }
            }

            addTagButton
        }
    }

    private var addTagButton: some View {
        Button {
            tagInput = ""
            showTagPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .font(.caption2)
                Text(L10n.addTag)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTagPopover, arrowEdge: .bottom) {
            tagPopoverContent
        }
    }

    private var tagPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(L10n.searchOrCreateTag, text: $tagInput)
                .textFieldStyle(.plain)
                .padding(10)
                .onSubmit {
                    submitTagInput()
                }

            Divider()

            if !suggestions.isEmpty || !tagInput.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.name) { tag in
                            tagSuggestionRow(name: tag.name, colorHex: tag.colorHex, isNew: false)
                        }

                        if shouldShowCreateSuggestion {
                            tagSuggestionRow(name: trimmedTagInput, colorHex: nil, isNew: true)
                        }
                    }
                }
                .frame(maxHeight: 240)
            } else {
                // 既存タグが無くて入力もない場合
                VStack {
                    Spacer()
                    Text(L10n.noResultsFound)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            }
        }
        .frame(width: 240)
    }

    private func tagSuggestionRow(name: String, colorHex: String?, isNew: Bool) -> some View {
        Button {
            guard let meetingId = ensureMeetingId() else { return }
            sidebarViewModel.addTagToMeeting(id: meetingId, tag: name)
            sidebarViewModel.selectMeeting(meetingId)
            tagInput = ""
        } label: {
            HStack(spacing: 6) {
                if isNew {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(Color(hex: colorHex ?? "#808080"))
                        .frame(width: 8, height: 8)
                }
                Text(name)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
    }

    private func submitTagInput() {
        guard !trimmedTagInput.isEmpty else { return }
        guard let meetingId = ensureMeetingId() else { return }
        sidebarViewModel.addTagToMeeting(id: meetingId, tag: trimmedTagInput.localizedLowercase)
        sidebarViewModel.selectMeeting(meetingId)
        tagInput = ""
    }

    private func ensureMeetingId() -> UUID? {
        if let meetingId = viewModel.currentMeetingId {
            return meetingId
        }
        return viewModel.materializeDraftMeeting()
    }
}

// MARK: - Tag Chip

private struct TagChip: View {
    let tag: TagInfo
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Color(hex: tag.colorHex))
                    .opacity(isHovered ? 0 : 1)

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityLabel(L10n.delete)
            }
            .frame(width: 10, height: 10)

            Text(tag.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: tag.colorHex).opacity(isHovered ? 0.16 : 0.1))
        )
        .frame(maxWidth: 220)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

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
    @State private var isHovered = false

    private var trimmedProjectInput: String {
        projectInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentProjectName: String? {
        guard let projectId = viewModel.currentProjectId else { return nil }
        return sidebarViewModel.flatProjects.first(where: { $0.id == projectId })?.name
    }

    private var filteredProjects: [FlatProjectRow] {
        guard !trimmedProjectInput.isEmpty else { return sidebarViewModel.flatProjects }
        let query = trimmedProjectInput.localizedLowercase
        return sidebarViewModel.flatProjects.filter { project in
            project.name.localizedLowercase.contains(query) || project.displayName.localizedLowercase.contains(query)
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
                    .opacity(isHovered && viewModel.currentProjectId != nil ? 0 : 1)

                if viewModel.currentProjectId != nil {
                    Button(action: clearProject) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10, height: 10)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                    .accessibilityLabel(L10n.delete)
                }
            }
            .frame(width: 10, height: 10)

            Button(action: presentProjectPopover) {
                HStack(spacing: 4) {
                    if style == .regular {
                        Text(currentProjectName ?? L10n.noProject)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .medium))
                }
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, style == .compact ? 6 : 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0.06))
        )
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering in
            isHovered = hovering
        }
        .popover(isPresented: $showProjectPopover, arrowEdge: .bottom) {
            projectPopoverContent
        }
        .help(currentProjectName ?? L10n.noProject)
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
                        .font(.callout)
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
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(name)
                    .font(.callout)
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
        assignMeeting(to: project.record.id, projectName: project.record.name)
    }

    private func clearProject() {
        guard viewModel.currentProjectId != nil else {
            projectInput = ""
            showProjectPopover = false
            return
        }

        guard let meetingId = viewModel.materializeDraftMeeting() else { return }
        sidebarViewModel.moveMeeting(id: meetingId, toProjectId: nil)
        viewModel.updateCurrentProjectContext(projectURL: nil, projectId: nil, projectName: nil)
        sidebarViewModel.selectMeeting(meetingId)
        projectInput = ""
        showProjectPopover = false
    }

    private func assignMeeting(to projectId: UUID, projectName: String) {
        let projectURL = sidebarViewModel.projectURL(for: projectName)
        guard let meetingId = viewModel.materializeDraftMeeting(
            projectURL: projectURL,
            projectId: projectId,
            projectName: projectName
        ) else { return }

        if projectId != viewModel.currentProjectId {
            sidebarViewModel.moveMeeting(id: meetingId, toProjectId: projectId)
        }
        viewModel.updateCurrentProjectContext(
            projectURL: projectURL,
            projectId: projectId,
            projectName: projectName
        )
        sidebarViewModel.selectMeeting(meetingId)
        projectInput = ""
        showProjectPopover = false
    }
}

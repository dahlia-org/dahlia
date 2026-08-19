import SwiftUI

struct MainSearchPanel: View {
    @Bindable var model: MainSearchModel
    var sidebarViewModel: SidebarViewModel
    let panelWidth: CGFloat
    let appearanceForProject: (UUID) -> ProjectAppearance
    let onDismiss: () -> Void
    let onOpenMeeting: (UUID) -> Void
    let onOpenProject: (UUID) -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .dahliaFixedSymbol()
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                TextField(L10n.searchMeetingsAndProjects, text: $model.inputText)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($isSearchFocused)
                    .onSubmit(activateSelectionOrSubmit)
                Button(L10n.close, systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .dahliaFixedSymbol()
                    .buttonStyle(.plain)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .help(L10n.close)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 72)

            if !model.tokens.isEmpty {
                MainSearchTokenRow(
                    tokens: model.tokens,
                    projects: sidebarViewModel.flatProjects,
                    tags: sidebarViewModel.allTags,
                    onRemove: { model.removeToken($0, using: sidebarViewModel) }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            MainSearchSuggestions(model: model, sidebarViewModel: sidebarViewModel)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        searchContent
                    }
                    .padding(16)
                }
                .onChange(of: model.selectedResultID) { _, selectedResultID in
                    guard let selectedResultID else { return }
                    proxy.scrollTo(selectedResultID, anchor: .center)
                }
            }
        }
        .frame(width: panelWidth)
        .frame(maxHeight: MainSearchDesign.panelMaximumHeight)
        .background(.background, in: .rect(cornerRadius: MainSearchDesign.panelCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: MainSearchDesign.panelCornerRadius)
                .stroke(.separator, lineWidth: 1)
        }
        .containerShape(.rect(cornerRadius: MainSearchDesign.panelCornerRadius))
        .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
        .onAppear {
            isSearchFocused = true
            model.catalogDidChange(using: sidebarViewModel)
        }
        .onChange(of: model.inputText) {
            model.queryDidChange(using: sidebarViewModel)
        }
        .onChange(of: sidebarViewModel.allProjectItems) {
            model.catalogDidChange(using: sidebarViewModel)
        }
        .onChange(of: sidebarViewModel.isProjectCatalogLoaded) {
            model.catalogDidChange(using: sidebarViewModel)
        }
        .onChange(of: sidebarViewModel.projectCatalogLoadFailed) {
            model.catalogDidChange(using: sidebarViewModel)
        }
        .onChange(of: sidebarViewModel.areSearchProjectsLoaded) {
            model.catalogDidChange(using: sidebarViewModel)
        }
        .onChange(of: sidebarViewModel.areSearchTagsLoaded) {
            model.catalogDidChange(using: sidebarViewModel)
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if let errorMessage = model.errorMessage {
            ContentUnavailableView(
                L10n.searchUnavailable,
                systemImage: "exclamationmark.magnifyingglass",
                description: Text(errorMessage)
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if model.isLoading, !model.hasResults, !model.isProjectCatalogLoading {
            ProgressView(L10n.searchingMeetings)
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if !model.hasResults,
                  !model.isProjectCatalogLoading,
                  !model.projectCatalogLoadFailed {
            ContentUnavailableView.search
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            if !model.meetings.isEmpty {
                sectionHeader(model.isRecent ? L10n.recentMeetings : L10n.meetings)
                ForEach(Array(model.meetings.enumerated()), id: \.element.id) { index, meeting in
                    meetingRow(meeting, index: index)
                }
                if model.hasMoreMeetings {
                    Button(L10n.loadMore) { model.loadMore(using: sidebarViewModel) }
                        .buttonStyle(.plain)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .disabled(model.isLoading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }

            if model.isProjectCatalogLoading {
                sectionHeader(model.isRecent ? L10n.recentProjects : L10n.projects)
                    .padding(.top, model.meetings.isEmpty ? 0 : 12)
                ProgressView(L10n.loadingProjects)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if model.projectCatalogLoadFailed {
                sectionHeader(model.isRecent ? L10n.recentProjects : L10n.projects)
                    .padding(.top, model.meetings.isEmpty ? 0 : 12)
                Label(L10n.searchUnavailable, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if !model.projects.isEmpty {
                sectionHeader(model.isRecent ? L10n.recentProjects : L10n.projects)
                    .padding(.top, model.meetings.isEmpty ? 0 : 12)
                ForEach(model.projects) { project in
                    MainSearchResultRow(
                        title: project.projectName,
                        inlineDetail: L10n.meetingCount(project.meetingCount),
                        leadingProjectAppearance: appearanceForProject(project.id),
                        isSelected: model.selectedResultID == .project(project.id),
                        action: { onOpenProject(project.id) }
                    )
                    .id(MainSearchResultID.project(project.id))
                }
            }

            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }

    private func meetingRow(_ meeting: MeetingSidebarItem, index: Int) -> some View {
        let shortcutNumber = index < 9 ? index + 1 : nil
        let shortcut = shortcutNumber.map {
            KeyboardShortcut(KeyEquivalent(Character(String($0))), modifiers: .command)
        }
        return MainSearchResultRow(
            title: meeting.displayTitle,
            projectBadge: meeting.projectName,
            projectTint: meeting.projectId.map { appearanceForProject($0).color.color },
            dateText: meeting.effectiveRecordingStartedAt.formatted(date: .numeric, time: .shortened),
            shortcutNumber: shortcutNumber,
            isSelected: model.selectedResultID == .meeting(meeting.id),
            action: { onOpenMeeting(meeting.id) }
        )
        .keyboardShortcut(shortcut)
        .id(MainSearchResultID.meeting(meeting.id))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.body)
            .foregroundStyle(DahliaDesign.secondaryTextColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func activateSelectionOrSubmit() {
        if model.submit(using: sidebarViewModel) {
            return
        }
        switch model.selectedResultID {
        case let .meeting(id): onOpenMeeting(id)
        case let .project(id): onOpenProject(id)
        case nil: break
        }
    }
}

import SwiftUI

struct MeetingSidebarSearchSuggestions: View {
    let searchText: String
    let searchTokens: [MeetingSearchToken]
    let isInputTruncated: Bool
    let mode: MeetingSidebarSearchModifier.SearchSuggestionMode
    let projects: [FlatProjectRow]
    let tags: [TagRecord]
    let areProjectsLoaded: Bool
    let areTagsLoaded: Bool
    let onSelectMode: (MeetingSidebarSearchModifier.SearchSuggestionMode) -> Void
    let onSelectProject: (FlatProjectRow) -> Void
    let onSelectTag: (TagRecord) -> Void
    let onSelectRecentDays: (Int) -> Void
    let onSelectCustomDateRange: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchCategoryButtons

            if isInputTruncated {
                Label(
                    L10n.searchInputLimitReached(MeetingSearchQueryParser.maximumInputLength),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            switch mode {
            case .overview:
                EmptyView()
            case let .projects(query):
                projectSuggestions(query: query)
            case let .tags(query):
                tagSuggestions(query: query)
            case .period:
                periodSuggestions
            }

            if !searchText.isEmpty || !searchTokens.isEmpty {
                Button(
                    L10n.clearAllSearchConditions,
                    systemImage: "xmark.circle",
                    action: onClear
                )
                .buttonStyle(.plain)
            }

        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var searchCategoryButtons: some View {
        HStack(spacing: 6) {
            searchCategoryButton(
                title: L10n.project,
                qualifier: "project:",
                systemImage: "folder",
                mode: .projects("")
            )
            searchCategoryButton(
                title: L10n.tag,
                qualifier: "tag:",
                systemImage: "tag",
                mode: .tags("")
            )
            searchCategoryButton(
                title: L10n.period,
                qualifier: "after:",
                systemImage: "calendar",
                mode: .period
            )
        }
        .controlSize(.small)
    }

    private func searchCategoryButton(
        title: String,
        qualifier: String,
        systemImage: String,
        mode: MeetingSidebarSearchModifier.SearchSuggestionMode
    ) -> some View {
        Button {
            onSelectMode(mode)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .help("\(title) · \(qualifier)")
        .searchCompletion(searchText)
    }

    @ViewBuilder
    private func projectSuggestions(query: String) -> some View {
        let matchingProjects = filteredProjects(query: query)
        Text(L10n.projectsAnyMatch)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        if !areProjectsLoaded {
            loadingSuggestionsLabel(L10n.loadingProjects)
        } else if !query.isEmpty, matchingProjects.isEmpty {
            Text(L10n.noProjectsMatchFilter)
                .foregroundStyle(.secondary)
        } else if projects.isEmpty {
            Text(L10n.noProjectsYet)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matchingProjects) { project in
                        Button {
                            onSelectProject(project)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(project.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                if project.hasChildren {
                                    Text(L10n.includesSubprojects)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                if searchTokens.contains(
                                    where: { $0.id == MeetingSearchToken.projectIdentifier(project.id) }
                                ) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    @ViewBuilder
    private func tagSuggestions(query: String) -> some View {
        let matchingTags = filteredTags(query: query)
        Text(L10n.tagsAnyMatch)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        if !areTagsLoaded {
            loadingSuggestionsLabel(L10n.loadingTags)
        } else if !query.isEmpty, matchingTags.isEmpty {
            Text(L10n.noMatchingTags)
                .foregroundStyle(.secondary)
        } else if tags.isEmpty {
            Text(L10n.noTagsYet)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matchingTags) { tag in
                        Button {
                            onSelectTag(tag)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(hex: tag.colorHex))
                                    .frame(width: 8, height: 8)
                                Text(tag.name)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let id = tag.id,
                                   searchTokens.contains(where: { $0.id == MeetingSearchToken.tagIdentifier(id) }) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private var periodSuggestions: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.period)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            periodButton(title: L10n.today, days: 1)
            periodButton(title: L10n.pastSevenDays, days: 7)
            periodButton(title: L10n.pastThirtyDays, days: 30)

            Button {
                onSelectCustomDateRange()
            } label: {
                Label(L10n.customDateRange, systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    private func periodButton(title: String, days: Int) -> some View {
        Button {
            onSelectRecentDays(days)
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private func loadingSuggestionsLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    private func filteredProjects(query: String) -> [FlatProjectRow] {
        guard !query.isEmpty else { return projects }
        return projects.filter {
            $0.name.localizedStandardContains(query)
                || $0.displayName.localizedStandardContains(query)
        }
    }

    private func filteredTags(query: String) -> [TagRecord] {
        guard !query.isEmpty else { return tags }
        return tags.filter { $0.name.localizedStandardContains(query) }
    }
}

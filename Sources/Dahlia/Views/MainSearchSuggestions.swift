import SwiftUI

struct MainSearchSuggestions: View {
    @Bindable var model: MainSearchModel
    var sidebarViewModel: SidebarViewModel

    @State private var mode: Mode = .overview
    @State private var customDateStart = Calendar.current.startOfDay(for: .now)
    @State private var customDateEnd = Calendar.current.startOfDay(for: .now)
    @State private var isCustomDateRangePresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                categoryButton(L10n.project, systemImage: "folder", mode: .projects)
                categoryButton(L10n.tag, systemImage: "tag", mode: .tags)
                categoryButton(L10n.period, systemImage: "calendar", mode: .period)
            }

            switch mode {
            case .overview:
                EmptyView()
            case .projects:
                projectSuggestions
            case .tags:
                tagSuggestions
            case .period:
                periodSuggestions
            }

            if !model.inputText.isEmpty || !model.tokens.isEmpty {
                Button(L10n.clearAllSearchConditions, systemImage: "xmark.circle") {
                    model.clearConditions(using: sidebarViewModel)
                    mode = .overview
                }
                .buttonStyle(.plain)
            }
        }
        .controlSize(.small)
        .sheet(isPresented: $isCustomDateRangePresented) {
            MeetingSearchDateRangeView(
                startDate: $customDateStart,
                endDate: $customDateEnd,
                onCancel: { isCustomDateRangePresented = false },
                onApply: applyCustomDateRange
            )
        }
    }

    private func categoryButton(_ title: String, systemImage: String, mode: Mode) -> some View {
        Button(title, systemImage: systemImage) {
            self.mode = self.mode == mode ? .overview : mode
        }
        .buttonStyle(.bordered)
        .accessibilityAddTraits(self.mode == mode ? .isSelected : [])
    }

    @ViewBuilder
    private var projectSuggestions: some View {
        if !sidebarViewModel.areSearchProjectsLoaded {
            loadingLabel(L10n.loadingProjects)
        } else if sidebarViewModel.flatProjects.isEmpty {
            Text(L10n.noProjectsYet)
                .foregroundStyle(.secondary)
        } else {
            suggestionList {
                ForEach(sidebarViewModel.flatProjects) { project in
                    selectionButton(
                        title: project.name,
                        systemImage: "folder",
                        isSelected: model.tokens.contains {
                            $0.id == MeetingSearchToken.projectIdentifier(project.id)
                        }
                    ) {
                        model.toggleProject(project, using: sidebarViewModel)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tagSuggestions: some View {
        if !sidebarViewModel.areSearchTagsLoaded {
            loadingLabel(L10n.loadingTags)
        } else if sidebarViewModel.allTags.isEmpty {
            Text(L10n.noTagsYet)
                .foregroundStyle(.secondary)
        } else {
            suggestionList {
                ForEach(sidebarViewModel.allTags) { tag in
                    if let id = tag.id {
                        selectionButton(
                            title: tag.name,
                            systemImage: "tag",
                            isSelected: model.tokens.contains {
                                $0.id == MeetingSearchToken.tagIdentifier(id)
                            }
                        ) {
                            model.toggleTag(tag, using: sidebarViewModel)
                        }
                    }
                }
            }
        }
    }

    private var periodSuggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            periodButton(L10n.today, days: 1)
            periodButton(L10n.pastSevenDays, days: 7)
            periodButton(L10n.pastThirtyDays, days: 30)
            Button(L10n.customDateRange, systemImage: "calendar.badge.plus") {
                prepareCustomDateRange()
                isCustomDateRangePresented = true
            }
            .buttonStyle(.plain)
        }
    }

    private func periodButton(_ title: String, days: Int) -> some View {
        Button(title) {
            model.applyRecentPeriod(days, using: sidebarViewModel)
        }
        .buttonStyle(.plain)
    }

    private func selectionButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func suggestionList(@ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, content: content)
        }
        .frame(maxHeight: 180)
    }

    private func loadingLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    private func prepareCustomDateRange() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let defaultStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        guard let token = model.tokens.first(where: { $0.id == MeetingSearchToken.dateRangeIdentifier }),
              case let .dateRange(startDate, endDate) = token.value else {
            customDateStart = defaultStart
            customDateEnd = today
            return
        }
        customDateStart = startDate ?? defaultStart
        customDateEnd = endDate.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) } ?? today
    }

    private func applyCustomDateRange() {
        model.applyDateRange(
            startDate: customDateStart,
            endDate: customDateEnd,
            using: sidebarViewModel
        )
        isCustomDateRangePresented = false
    }

    private enum Mode: Equatable {
        case overview
        case projects
        case tags
        case period
    }
}

import SwiftUI

struct MainSearchSuggestions: View {
    @Bindable var model: MainSearchModel
    var sidebarViewModel: SidebarViewModel
    @Binding var mode: Mode

    @State private var customDateStart = Calendar.current.startOfDay(for: .now)
    @State private var customDateEnd = Calendar.current.startOfDay(for: .now)
    @State private var isCustomDateRangePresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private var projectSuggestions: some View {
        if !sidebarViewModel.areSearchProjectsLoaded {
            loadingLabel(L10n.loadingProjects)
        } else if sidebarViewModel.flatProjects.isEmpty {
            Text(L10n.noProjectsYet)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
        } else {
            suggestionList {
                ForEach(sidebarViewModel.flatProjects) { project in
                    MainSearchSuggestionButton(
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
                .foregroundStyle(DahliaDesign.secondaryTextColor)
        } else {
            suggestionList {
                ForEach(sidebarViewModel.allTags) { tag in
                    if let id = tag.id {
                        MainSearchSuggestionButton(
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
            MainSearchSuggestionButton(
                title: L10n.customDateRange,
                systemImage: "calendar.badge.plus",
                isSelected: false
            ) {
                prepareCustomDateRange()
                isCustomDateRangePresented = true
            }
        }
    }

    private func periodButton(_ title: String, days: Int) -> some View {
        MainSearchSuggestionButton(title: title, isSelected: false) {
            model.applyRecentPeriod(days, using: sidebarViewModel)
        }
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
                .foregroundStyle(DahliaDesign.secondaryTextColor)
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

    enum Mode: Equatable {
        case overview
        case projects
        case tags
        case period
    }
}

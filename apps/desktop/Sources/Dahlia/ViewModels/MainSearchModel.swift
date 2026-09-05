import Foundation
import Observation

@MainActor
@Observable
final class MainSearchModel {
    private(set) var isPresented = false
    var inputText = ""
    private(set) var tokens: [MeetingSearchToken] = []
    private(set) var meetings: [MeetingSidebarItem] = []
    private(set) var screenshots: [ScreenshotSearchResult] = []
    private(set) var projects: [ProjectOverviewItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isProjectCatalogLoading = false
    private(set) var projectCatalogLoadFailed = false
    private(set) var hasMoreMeetings = false
    private(set) var hasMoreScreenshots = false
    private(set) var isLoadingScreenshots = false
    private var hasCompletedInitialMeetingSearch = false
    private(set) var isRecent = true
    var selectedResultID: MainSearchResultID?

    @ObservationIgnored private var meetingCursor: MeetingSearchCursor?
    @ObservationIgnored private var screenshotCursor: ScreenshotSearchCursor?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var projectSearchTask: Task<Void, Never>?
    @ObservationIgnored private var screenshotSearchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var screenshotGeneration = 0
    @ObservationIgnored private var projectGeneration = 0
    @ObservationIgnored private var activeMeetingCriteria = MeetingSearchCriteria()
    @ObservationIgnored private var activeRankingPolicy: MeetingSearchRankingPolicy?
    @ObservationIgnored private var pendingQualifierText: String?

    var resultIDs: [MainSearchResultID] {
        meetings.map { .meeting($0.id) }
            + presentedScreenshots.map { .screenshot($0.id) }
            + projects.map { .project($0.id) }
    }

    var presentedScreenshots: [ScreenshotSearchResult] {
        hasCompletedInitialMeetingSearch ? screenshots : []
    }

    var hasResults: Bool {
        !meetings.isEmpty || !presentedScreenshots.isEmpty || !projects.isEmpty
    }

    func present(using sidebarViewModel: SidebarViewModel) {
        resetSearch()
        isPresented = true
        startSearch(using: sidebarViewModel, delay: nil, appending: false)
    }

    func dismiss() {
        isPresented = false
        resetSearch()
    }

    func queryDidChange(using sidebarViewModel: SidebarViewModel) {
        if inputText.count > MeetingSearchQueryParser.maximumInputLength {
            inputText = String(inputText.prefix(MeetingSearchQueryParser.maximumInputLength))
            return
        }
        startSearch(using: sidebarViewModel, delay: .milliseconds(250), appending: false)
    }

    @discardableResult
    func submit(using sidebarViewModel: SidebarViewModel) -> Bool {
        let result = MeetingSearchQueryParser.parse(
            inputText,
            existingTokens: tokens,
            projects: sidebarViewModel.flatProjects,
            tags: sidebarViewModel.allTags,
            allowsTerminalUnquotedValue: true
        )
        let didResolveQualifier = result.text != inputText || result.tokens != tokens
        guard didResolveQualifier else {
            guard let qualifier = terminalCatalogQualifier else { return false }
            if !catalogIsLoaded(for: qualifier, using: sidebarViewModel) {
                pendingQualifierText = inputText
            }
            return true
        }
        pendingQualifierText = nil
        inputText = result.text
        tokens = result.tokens
        startSearch(using: sidebarViewModel, delay: nil, appending: false)
        return true
    }

    func removeToken(_ token: MeetingSearchToken, using sidebarViewModel: SidebarViewModel) {
        tokens.removeAll { $0.id == token.id }
        startSearch(using: sidebarViewModel, delay: nil, appending: false)
    }

    func catalogDidChange(using sidebarViewModel: SidebarViewModel) {
        guard isPresented else { return }
        guard !resolvePendingQualifierIfPossible(using: sidebarViewModel) else { return }
        let criteria = searchCriteria(using: sidebarViewModel)
        if criteria != activeMeetingCriteria {
            startSearch(using: sidebarViewModel, delay: nil, appending: false)
        } else {
            startProjectSearch(criteria: criteria, using: sidebarViewModel)
        }
    }

    func loadMore(using sidebarViewModel: SidebarViewModel) {
        guard hasMoreMeetings, !isLoading else { return }
        startSearch(using: sidebarViewModel, delay: nil, appending: true)
    }

    func loadMoreScreenshots(using sidebarViewModel: SidebarViewModel) {
        guard hasMoreScreenshots, !isLoadingScreenshots else { return }
        startScreenshotSearch(
            criteria: activeMeetingCriteria,
            using: sidebarViewModel,
            appending: true
        )
    }

    func moveSelection(by offset: Int) {
        let ids = resultIDs
        guard !ids.isEmpty else {
            selectedResultID = nil
            return
        }
        guard let selectedResultID,
              let index = ids.firstIndex(of: selectedResultID) else {
            self.selectedResultID = offset < 0 ? ids.last : ids.first
            return
        }
        self.selectedResultID = ids[min(max(index + offset, 0), ids.count - 1)]
    }

    func resetForVaultChange(using sidebarViewModel: SidebarViewModel) {
        guard isPresented else {
            resetSearch()
            return
        }
        resetSearch()
        startSearch(using: sidebarViewModel, delay: nil, appending: false)
    }

    private func resetSearch() {
        searchTask?.cancel()
        projectSearchTask?.cancel()
        screenshotSearchTask?.cancel()
        generation &+= 1
        screenshotGeneration &+= 1
        projectGeneration &+= 1
        inputText = ""
        tokens = []
        meetings = []
        screenshots = []
        projects = []
        isLoading = false
        errorMessage = nil
        isProjectCatalogLoading = false
        projectCatalogLoadFailed = false
        hasMoreMeetings = false
        hasMoreScreenshots = false
        isLoadingScreenshots = false
        hasCompletedInitialMeetingSearch = false
        meetingCursor = nil
        screenshotCursor = nil
        activeMeetingCriteria = MeetingSearchCriteria()
        activeRankingPolicy = nil
        selectedResultID = nil
        isRecent = true
        pendingQualifierText = nil
    }

    private func startSearch(
        using sidebarViewModel: SidebarViewModel,
        delay: Duration?,
        appending: Bool
    ) {
        searchTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        let vaultID = sidebarViewModel.currentVault?.id
        let dbQueue = sidebarViewModel.searchDBQueue
        let criteria = searchCriteria(using: sidebarViewModel)
        let rankingPolicy = AppSettings.shared.meetingSearchRankingPolicy
        let appendsCurrentRanking = appending && activeRankingPolicy == rankingPolicy
        activeMeetingCriteria = criteria
        activeRankingPolicy = rankingPolicy
        let cursor = appendsCurrentRanking ? meetingCursor : nil
        let limit = criteria.isEmpty ? MainSearchDesign.recentResultLimit : MainSearchDesign.meetingPageSize

        preparePresentation(criteria: criteria, appending: appendsCurrentRanking)
        if !appendsCurrentRanking {
            startProjectSearch(criteria: criteria, using: sidebarViewModel)
            startScreenshotSearch(
                criteria: criteria,
                using: sidebarViewModel,
                appending: false,
                delay: delay
            )
        }

        guard let vaultID, let dbQueue else {
            isLoading = false
            errorMessage = L10n.searchRequiresVault
            return
        }

        searchTask = Task { [weak self] in
            do {
                if let delay {
                    try await Task.sleep(for: delay)
                }
                let page = try await MeetingRepository.searchMeetingSidebarPage(
                    vaultId: vaultID,
                    criteria: criteria,
                    rankingPolicy: rankingPolicy,
                    after: cursor,
                    limit: limit,
                    dbQueue: dbQueue
                )
                try Task.checkCancellation()
                guard let self,
                      self.generation == requestGeneration,
                      sidebarViewModel.currentVault?.id == vaultID else { return }
                self.apply(page, appending: appendsCurrentRanking)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ page: MeetingSearchPage, appending: Bool) {
        if appending, !page.replacesResults {
            meetings.append(contentsOf: page.items)
        } else {
            meetings = page.items
        }
        meetingCursor = page.nextCursor
        hasMoreMeetings = page.hasMore
        isLoading = false
        if !appending { hasCompletedInitialMeetingSearch = true }
        clearInvalidSelection()
    }

    private func preparePresentation(
        criteria: MeetingSearchCriteria,
        appending: Bool
    ) {
        isRecent = criteria.isEmpty
        errorMessage = nil
        isLoading = true
        guard !appending else { return }
        meetings = []
        screenshots = []
        projects = []
        meetingCursor = nil
        screenshotCursor = nil
        hasMoreMeetings = false
        hasMoreScreenshots = false
        hasCompletedInitialMeetingSearch = false
        selectedResultID = nil
    }

    private func startScreenshotSearch(
        criteria: MeetingSearchCriteria,
        using sidebarViewModel: SidebarViewModel,
        appending: Bool,
        delay: Duration? = nil
    ) {
        screenshotSearchTask?.cancel()
        screenshotGeneration &+= 1
        let requestGeneration = screenshotGeneration
        guard !criteria.text.isEmpty,
              let vaultID = sidebarViewModel.currentVault?.id,
              let dbQueue = sidebarViewModel.searchDBQueue else {
            if !appending { screenshots = [] }
            hasMoreScreenshots = false
            isLoadingScreenshots = false
            return
        }
        let cursor = appending ? screenshotCursor : nil
        isLoadingScreenshots = true
        screenshotSearchTask = Task { [weak self] in
            do {
                if let delay {
                    try await Task.sleep(for: delay)
                }
                let page = try await MeetingRepository.searchScreenshotPage(
                    vaultID: vaultID,
                    criteria: criteria,
                    after: cursor,
                    limit: MainSearchDesign.screenshotPageSize,
                    dbQueue: dbQueue
                )
                try Task.checkCancellation()
                guard let self,
                      self.screenshotGeneration == requestGeneration,
                      sidebarViewModel.currentVault?.id == vaultID else { return }
                if appending, !page.replacesResults {
                    self.screenshots.append(contentsOf: page.items)
                } else {
                    self.screenshots = page.items
                }
                self.screenshotCursor = page.nextCursor
                self.hasMoreScreenshots = page.nextCursor != nil
                self.isLoadingScreenshots = false
                self.clearInvalidSelection()
            } catch is CancellationError {
            } catch {
                guard let self, self.screenshotGeneration == requestGeneration else { return }
                self.isLoadingScreenshots = false
            }
        }
    }

    func screenshotImageData(id: UUID, using sidebarViewModel: SidebarViewModel) async -> Data? {
        guard let vaultID = sidebarViewModel.currentVault?.id,
              let dbQueue = sidebarViewModel.searchDBQueue else { return nil }
        return try? await MeetingRepository.screenshotImageData(id: id, vaultID: vaultID, dbQueue: dbQueue)
    }

    private func startProjectSearch(
        criteria: MeetingSearchCriteria,
        using sidebarViewModel: SidebarViewModel
    ) {
        projectSearchTask?.cancel()
        projectGeneration &+= 1
        let requestGeneration = projectGeneration

        projects = []
        clearInvalidSelection()
        isProjectCatalogLoading = false
        projectCatalogLoadFailed = sidebarViewModel.projectCatalogLoadFailed
        guard let vaultID = sidebarViewModel.currentVault?.id,
              let dbQueue = sidebarViewModel.searchDBQueue else { return }
        guard !projectCatalogLoadFailed else { return }
        guard sidebarViewModel.isProjectCatalogLoaded else {
            isProjectCatalogLoading = true
            return
        }

        isProjectCatalogLoading = true
        let projectItems = sidebarViewModel.allProjectItems
        projectSearchTask = Task { [weak self] in
            let results: [ProjectOverviewItem]
            if criteria.isEmpty {
                results = await Self.recentProjectResults(from: projectItems)
            } else if criteria.text.isEmpty {
                results = []
            } else {
                do {
                    let ids = try await MeetingRepository.searchProjectIDs(
                        vaultID: vaultID,
                        query: criteria.text,
                        limit: MainSearchDesign.projectResultLimit,
                        dbQueue: dbQueue
                    )
                    let byID = Dictionary(uniqueKeysWithValues: projectItems.map { ($0.id, $0) })
                    results = ids.compactMap { byID[$0] }
                } catch {
                    results = []
                }
            }
            guard let self, self.projectGeneration == requestGeneration else { return }
            self.projects = results
            self.isProjectCatalogLoading = false
            self.clearInvalidSelection()
        }
    }

    private func searchCriteria(using sidebarViewModel: SidebarViewModel) -> MeetingSearchCriteria {
        let result = MeetingSearchQueryParser.parse(
            inputText,
            existingTokens: tokens,
            projects: sidebarViewModel.flatProjects,
            tags: sidebarViewModel.allTags,
            allowsTerminalUnquotedValue: false
        )
        return MeetingSearchQueryParser.criteria(text: result.text, tokens: result.tokens)
    }

    private func clearInvalidSelection() {
        guard let selectedResultID, !resultIDs.contains(selectedResultID) else { return }
        self.selectedResultID = nil
    }

    private func resolvePendingQualifierIfPossible(using sidebarViewModel: SidebarViewModel) -> Bool {
        guard pendingQualifierText == inputText,
              let qualifier = terminalCatalogQualifier,
              catalogIsLoaded(for: qualifier, using: sidebarViewModel) else { return false }
        pendingQualifierText = nil
        let result = MeetingSearchQueryParser.parse(
            inputText,
            existingTokens: tokens,
            projects: sidebarViewModel.flatProjects,
            tags: sidebarViewModel.allTags,
            allowsTerminalUnquotedValue: true
        )
        guard result.text != inputText || result.tokens != tokens else { return false }
        inputText = result.text
        tokens = result.tokens
        startSearch(using: sidebarViewModel, delay: nil, appending: false)
        return true
    }

    private func catalogIsLoaded(
        for qualifier: CatalogQualifier,
        using sidebarViewModel: SidebarViewModel
    ) -> Bool {
        switch qualifier {
        case .project:
            sidebarViewModel.areSearchProjectsLoaded
        case .tag:
            sidebarViewModel.areSearchTagsLoaded
        }
    }

    private var terminalCatalogQualifier: CatalogQualifier? {
        let pattern = #"(?i)(?:^|\s)(project|tag):(?:\{[^}\n]*\}|"[^"\n]*"|[^\s]*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(inputText.startIndex ..< inputText.endIndex, in: inputText)
        guard let match = expression.firstMatch(in: inputText, range: range),
              let keyRange = Range(match.range(at: 1), in: inputText) else { return nil }
        return switch inputText[keyRange].lowercased() {
        case "project": .project
        case "tag": .tag
        default: nil
        }
    }

    private enum CatalogQualifier {
        case project
        case tag
    }
}

extension MainSearchModel {
    @concurrent private nonisolated static func recentProjectResults(
        from projects: [ProjectOverviewItem]
    ) async -> [ProjectOverviewItem] {
        Array(projects.sorted {
            ($0.latestMeetingDate ?? $0.createdAt) > ($1.latestMeetingDate ?? $1.createdAt)
        }.prefix(MainSearchDesign.recentResultLimit))
    }

    func toggleProject(_ project: FlatProjectRow, using sidebarViewModel: SidebarViewModel) {
        toggleToken(
            MeetingSearchToken(value: .project(id: project.id, name: project.name)),
            using: sidebarViewModel
        )
    }

    func toggleTag(_ tag: TagRecord, using sidebarViewModel: SidebarViewModel) {
        guard let id = tag.id else { return }
        toggleToken(
            MeetingSearchToken(value: .tag(id: id, name: tag.name, colorHex: tag.colorHex)),
            using: sidebarViewModel
        )
    }

    func applyRecentPeriod(_ days: Int, using sidebarViewModel: SidebarViewModel) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        replaceDateToken(
            MeetingSearchToken(value: .dateRange(startDate: startDate, endDate: nil)),
            using: sidebarViewModel
        )
    }

    func applyDateRange(
        startDate: Date,
        endDate: Date,
        using sidebarViewModel: SidebarViewModel
    ) {
        replaceDateToken(
            MeetingSearchToken.inclusiveDateRange(startDate: startDate, endDate: endDate),
            using: sidebarViewModel
        )
    }

    func clearConditions(using sidebarViewModel: SidebarViewModel) {
        inputText = ""
        tokens = []
        pendingQualifierText = nil
        startSearch(using: sidebarViewModel, delay: nil, appending: false)
    }

    private func toggleToken(_ token: MeetingSearchToken, using sidebarViewModel: SidebarViewModel) {
        if tokens.contains(where: { $0.id == token.id }) {
            tokens.removeAll { $0.id == token.id }
        } else {
            tokens.append(token)
        }
        startSearch(using: sidebarViewModel, delay: nil, appending: false)
    }

    private func replaceDateToken(_ token: MeetingSearchToken, using sidebarViewModel: SidebarViewModel) {
        tokens.removeAll { $0.id == MeetingSearchToken.dateRangeIdentifier }
        tokens.append(token)
        startSearch(using: sidebarViewModel, delay: nil, appending: false)
    }
}

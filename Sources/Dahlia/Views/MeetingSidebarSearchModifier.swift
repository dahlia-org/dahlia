import AppKit
import SwiftUI

struct MeetingSidebarSearchModifier: ViewModifier {
    @Binding var searchText: String
    @Binding var searchTokens: [MeetingSearchToken]
    var sidebarViewModel: SidebarViewModel

    @State private var customDateStart = Calendar.current.startOfDay(for: .now)
    @State private var customDateEnd = Calendar.current.startOfDay(for: .now)
    @State private var isCustomDateRangePresented = false
    @State private var isSearchInputTruncated = false
    @State private var committedTrailingQualifierText: String?
    @State private var suggestionModeOverrideText: String?
    @State private var pendingTerminalResolutionText: String?
    @State private var parserProducedSearchText: String?
    @State private var pasteCommandTracker = PasteCommandTracker()
    @State private var pasteEventMonitor: Any?
    @State private var outsideClickEventMonitor: Any?
    @State private var pasteMenuObserver: MeetingSearchPasteMenuObserver?
    @State private var activeSuggestionMode: SearchSuggestionMode = .overview
    @FocusState private var isSearchFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(
                text: boundedSearchText,
                tokens: $searchTokens,
                placement: .toolbar,
                prompt: L10n.searchMeetings
            ) { token in
                MeetingSearchTokenLabel(
                    token: token,
                    projects: sidebarViewModel.flatProjects,
                    tags: sidebarViewModel.allTags
                )
            }
            .searchFocused($isSearchFocused)
            .searchSuggestions {
                searchSuggestions
            }
            .sheet(isPresented: $isCustomDateRangePresented) {
                MeetingSearchDateRangeView(
                    startDate: $customDateStart,
                    endDate: $customDateEnd,
                    onCancel: dismissCustomDateRange,
                    onApply: applyCustomDateRange
                )
            }
            .onSubmit(of: .search) {
                submitSearch()
            }
            .onChange(of: searchText, searchTextChanged)
            .onChange(of: searchTokens) { _, newTokens in
                if newTokens.isEmpty, searchText.isEmpty {
                    isSearchInputTruncated = false
                    isCustomDateRangePresented = false
                }
                updateSearch()
            }
            .onChange(of: isSearchFocused, searchFocusChanged)
            .onChange(of: sidebarViewModel.areSearchProjectsLoaded, searchCatalogLoaded)
            .onChange(of: sidebarViewModel.areSearchTagsLoaded, searchCatalogLoaded)
            .onChange(of: sidebarViewModel.currentVault?.id) {
                clearSearch()
            }
            .onAppear {
                startMonitoringPasteCommands()
                startMonitoringOutsideClicks()
            }
            .onDisappear {
                stopMonitoringPasteCommands()
                stopMonitoringOutsideClicks()
            }
    }
}

private extension MeetingSidebarSearchModifier {
    private var searchSuggestions: some View {
        MeetingSidebarSearchSuggestions(
            searchText: searchText,
            searchTokens: searchTokens,
            isInputTruncated: isSearchInputTruncated,
            mode: searchSuggestionMode,
            projects: sidebarViewModel.flatProjects,
            tags: sidebarViewModel.allTags,
            areProjectsLoaded: sidebarViewModel.areSearchProjectsLoaded,
            areTagsLoaded: sidebarViewModel.areSearchTagsLoaded,
            onSelectMode: selectSuggestionMode,
            onSelectProject: addProjectToken,
            onSelectTag: addTagToken,
            onSelectRecentDays: applyRecentDays,
            onSelectCustomDateRange: presentCustomDateRange,
            onClear: clearSearchAfterSuggestionInteraction
        )
    }

    private var searchSuggestionMode: SearchSuggestionMode {
        guard Self.shouldUseTrailingQualifierMode(
            overrideText: suggestionModeOverrideText,
            currentText: searchText
        ),
            let qualifier = trailingQualifier else {
            return activeSuggestionMode
        }
        switch qualifier.key {
        case "project":
            return .projects(qualifier.query)
        case "tag":
            return .tags(qualifier.query)
        case "after", "before":
            return .period
        default:
            return .overview
        }
    }

    private var trailingQualifier: TrailingSearchQualifier? {
        TrailingSearchQualifier.find(in: searchText)
    }

    private var boundedSearchText: Binding<String> {
        Binding(
            get: { searchText },
            set: {
                let boundedInput = MeetingSearchQueryParser.boundedInput($0)
                isSearchInputTruncated = boundedInput != $0
                searchText = boundedInput
            }
        )
    }

    private func submitSearch() {
        let previousText = searchText
        parseCompletedSearchQualifiers(allowsTerminalUnquotedValue: true)
        rememberTerminalResolutionIfCatalogIsLoading()
        if searchText == previousText, trailingQualifier != nil {
            committedTrailingQualifierText = searchText
        }
        updateSearch()
    }

    private func searchTextChanged(_: String, _ newValue: String) {
        let wasProducedByParser = parserProducedSearchText == newValue
        parserProducedSearchText = nil
        if newValue.isEmpty, !wasProducedByParser {
            isSearchInputTruncated = false
        }
        if pendingTerminalResolutionText != newValue {
            pendingTerminalResolutionText = nil
        }
        committedTrailingQualifierText = nil
        suggestionModeOverrideText = nil
        let parsesTerminalValue = pasteCommandTracker.consumeNextTextChange()
        parseCompletedSearchQualifiers(allowsTerminalUnquotedValue: parsesTerminalValue)
        if parsesTerminalValue {
            rememberTerminalResolutionIfCatalogIsLoading()
        }
        if trailingQualifierIsExplicitlyClosed {
            committedTrailingQualifierText = searchText
        }
        updateSearch()
    }

    private func searchFocusChanged(_: Bool, _ isFocused: Bool) {
        guard !isFocused else { return }
        pasteCommandTracker.cancel()
        parseCompletedSearchQualifiers(allowsTerminalUnquotedValue: true)
        rememberTerminalResolutionIfCatalogIsLoading()
        if trailingQualifier?.query.isEmpty == true,
           committedTrailingQualifierText != searchText {
            removeTrailingQualifier()
        }
        activeSuggestionMode = .overview
        suggestionModeOverrideText = nil
        updateSearch()
    }

    private func searchCatalogLoaded(_: Bool, _ isLoaded: Bool) {
        guard isLoaded else { return }
        resolveQualifiersAfterCatalogLoad()
    }

    private func addProjectToken(_ project: FlatProjectRow) {
        deferSuggestionMutation {
            let token = MeetingSearchToken(value: .project(id: project.id, name: project.name))
            toggleToken(token)
            removeTrailingQualifier()
            activeSuggestionMode = .projects("")
        }
    }

    private func addTagToken(_ tag: TagRecord) {
        guard let id = tag.id else { return }
        deferSuggestionMutation {
            let token = MeetingSearchToken(value: .tag(id: id, name: tag.name, colorHex: tag.colorHex))
            toggleToken(token)
            removeTrailingQualifier()
            activeSuggestionMode = .tags("")
        }
    }

    private func toggleToken(_ token: MeetingSearchToken) {
        if searchTokens.contains(where: { $0.id == token.id }) {
            searchTokens.removeAll { $0.id == token.id }
        } else {
            searchTokens.append(token)
        }
        isSearchFocused = true
    }

    private func applyRecentDays(_ days: Int) {
        deferSuggestionMutation {
            replaceDateToken(Self.recentPeriodToken(days: days))
            removeTrailingQualifier()
            isSearchFocused = true
        }
    }

    private func prepareCustomDateRange() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let defaultStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        guard let token = searchTokens.first(where: { $0.id == MeetingSearchToken.dateRangeIdentifier }),
              case let .dateRange(startDate, endDate) = token.value else {
            customDateStart = defaultStart
            customDateEnd = today
            return
        }
        customDateStart = startDate ?? defaultStart
        customDateEnd = endDate.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) } ?? today
    }

    private func presentCustomDateRange() {
        deferSuggestionMutation {
            prepareCustomDateRange()
            removeTrailingQualifier()
            activeSuggestionMode = .overview
            isCustomDateRangePresented = true
        }
    }

    private func dismissCustomDateRange() {
        isCustomDateRangePresented = false
    }

    private func applyCustomDateRange() {
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: customDateStart)
        let inclusiveEndDate = calendar.startOfDay(for: customDateEnd)
        guard startDate <= inclusiveEndDate else { return }
        replaceDateToken(MeetingSearchToken.inclusiveDateRange(
            startDate: startDate,
            endDate: inclusiveEndDate,
            calendar: calendar
        ))
        removeTrailingQualifier()
        activeSuggestionMode = .overview
        isSearchFocused = true
        isCustomDateRangePresented = false
    }

    private func replaceDateToken(_ token: MeetingSearchToken) {
        searchTokens.removeAll { $0.id == MeetingSearchToken.dateRangeIdentifier }
        searchTokens.append(token)
    }

    private func parseCompletedSearchQualifiers(allowsTerminalUnquotedValue: Bool) {
        applyParseResult(MeetingSearchQueryParser.parse(
            searchText,
            existingTokens: searchTokens,
            projects: sidebarViewModel.flatProjects,
            tags: sidebarViewModel.allTags,
            allowsTerminalUnquotedValue: allowsTerminalUnquotedValue
        ))
    }

    private func applyParseResult(_ result: MeetingSearchParseResult) {
        guard result.text != searchText || result.tokens != searchTokens else { return }
        if result.text != searchText {
            parserProducedSearchText = result.text
            searchText = result.text
        }
        searchTokens = result.tokens
    }

    private func resolveQualifiersAfterCatalogLoad() {
        let vaultID = sidebarViewModel.currentVault?.id
        Task { @MainActor in
            await Task.yield()
            guard sidebarViewModel.currentVault?.id == vaultID,
                  trailingQualifierCatalogIsLoaded else { return }
            let resolvesTerminalValue = Self.shouldResolveTerminalQualifierAfterCatalogLoad(
                pendingText: pendingTerminalResolutionText,
                currentText: searchText
            )
            parseCompletedSearchQualifiers(allowsTerminalUnquotedValue: resolvesTerminalValue)
            if resolvesTerminalValue {
                pendingTerminalResolutionText = trailingQualifierCatalogIsLoading ? searchText : nil
            }
            updateSearch()
        }
    }

    private func updateSearch() {
        let criteria = MeetingSearchQueryParser.criteria(
            text: searchTextExcludingTrailingQualifier,
            tokens: searchTokens
        )
        sidebarViewModel.updateMeetingSearchCriteria(criteria)
    }

    private var searchTextExcludingTrailingQualifier: String {
        if committedTrailingQualifierText == searchText {
            return searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let trailingQualifier else {
            return searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(searchText[..<trailingQualifier.range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeTrailingQualifier() {
        searchText = TrailingSearchQualifier.removingUncommittedQualifier(
            from: searchText,
            committedText: committedTrailingQualifierText
        )
    }

    private func clearSearch() {
        searchText = ""
        searchTokens.removeAll()
        isCustomDateRangePresented = false
        isSearchInputTruncated = false
        committedTrailingQualifierText = nil
        suggestionModeOverrideText = nil
        pendingTerminalResolutionText = nil
        parserProducedSearchText = nil
        pasteCommandTracker.cancel()
        activeSuggestionMode = .overview
        sidebarViewModel.updateMeetingSearchCriteria(MeetingSearchCriteria())
    }

    private func clearSearchAfterSuggestionInteraction() {
        deferSuggestionMutation {
            clearSearch()
        }
    }

    private func selectSuggestionMode(_ mode: SearchSuggestionMode) {
        deferSuggestionMutation {
            parseCompletedSearchQualifiers(allowsTerminalUnquotedValue: true)
            if let trailingQualifier {
                if trailingQualifier.query.isEmpty {
                    removeTrailingQualifier()
                } else {
                    committedTrailingQualifierText = searchText
                    suggestionModeOverrideText = searchText
                    rememberTerminalResolutionIfCatalogIsLoading()
                }
            }
            activeSuggestionMode = mode
            isSearchFocused = true
            updateSearch()
        }
    }

    private func deferSuggestionMutation(
        _ mutation: @escaping @MainActor () -> Void
    ) {
        let vaultID = sidebarViewModel.currentVault?.id
        Task { @MainActor in
            await Task.yield()
            guard sidebarViewModel.currentVault?.id == vaultID else { return }
            mutation()
        }
    }

    private var trailingQualifierIsExplicitlyClosed: Bool {
        guard let trailingQualifier else { return false }
        let rawQualifier = searchText[trailingQualifier.range]
        return rawQualifier.hasSuffix("}") || rawQualifier.hasSuffix("\"")
    }

    private var trailingQualifierCatalogIsLoaded: Bool {
        switch trailingQualifier?.key {
        case "project":
            sidebarViewModel.areSearchProjectsLoaded
        case "tag":
            sidebarViewModel.areSearchTagsLoaded
        default:
            true
        }
    }

    private var trailingQualifierCatalogIsLoading: Bool {
        trailingQualifier != nil && !trailingQualifierCatalogIsLoaded
    }

    private func rememberTerminalResolutionIfCatalogIsLoading() {
        if trailingQualifierCatalogIsLoading {
            pendingTerminalResolutionText = searchText
        }
    }

    private func startMonitoringPasteCommands() {
        guard pasteEventMonitor == nil, pasteMenuObserver == nil else { return }
        pasteEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isSearchFocused else { return event }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                pasteCommandTracker.recordPasteCommand()
            } else {
                pasteCommandTracker.cancel()
            }
            return event
        }
        let menuObserver = MeetingSearchPasteMenuObserver {
            guard isSearchFocused else { return }
            pasteCommandTracker.recordPasteCommand()
        }
        NotificationCenter.default.addObserver(
            menuObserver,
            selector: #selector(MeetingSearchPasteMenuObserver.menuWillSendAction(_:)),
            name: NSMenu.willSendActionNotification,
            object: nil
        )
        pasteMenuObserver = menuObserver
    }

    private func stopMonitoringPasteCommands() {
        if let pasteEventMonitor {
            NSEvent.removeMonitor(pasteEventMonitor)
            self.pasteEventMonitor = nil
        }
        if let pasteMenuObserver {
            NotificationCenter.default.removeObserver(pasteMenuObserver)
            self.pasteMenuObserver = nil
        }
        pasteCommandTracker.cancel()
    }

    private func startMonitoringOutsideClicks() {
        guard outsideClickEventMonitor == nil else { return }
        outsideClickEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            guard isSearchFocused,
                  let window = event.window,
                  let fieldEditor = window.firstResponder as? NSTextView,
                  let searchField = fieldEditor.delegate as? NSSearchField else {
                return event
            }
            guard Self.shouldDismissSearch(
                eventWindow: window,
                searchField: searchField,
                clickLocationInWindow: event.locationInWindow
            ) else {
                return event
            }
            Task { @MainActor in
                await Task.yield()
                isSearchFocused = false
            }
            return event
        }
    }

    private func stopMonitoringOutsideClicks() {
        if let outsideClickEventMonitor {
            NSEvent.removeMonitor(outsideClickEventMonitor)
            self.outsideClickEventMonitor = nil
        }
    }

}

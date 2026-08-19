import Foundation
import GRDB
import OSLog

extension SidebarViewModel {
    func meetingDescription(id meetingId: UUID, vaultId: UUID) async -> String? {
        guard let dbQueue,
              currentVault?.id == vaultId else { return nil }
        return await (try? dbQueue.read { db in
            try MeetingRepository.fetchMeetingDescription(
                id: meetingId,
                vaultId: vaultId,
                in: db
            )
        })
    }

    func containsMeeting(id meetingId: UUID) async -> Bool {
        guard let dbQueue,
              let vaultId = currentVault?.id else { return false }
        return await (try? dbQueue.read { db in
            try MeetingRecord.fetchOne(db, key: meetingId)?.vaultId == vaultId
        }) == true && currentVault?.id == vaultId
    }

    var meetingSearchQuery: String {
        meetingSearchCriteria.text
    }

    var isSearchingMeetings: Bool {
        !meetingSearchCriteria.isEmpty
    }

    var displayedMeetingItems: [MeetingSidebarItem] {
        isSearchingMeetings ? meetingSearchItems : meetingSidebarItems
    }

    var displayedMeetingGroups: [MeetingDateGroup] {
        isSearchingMeetings ? meetingSearchGroups : meetingSidebarGroups
    }

    var isDisplayedMeetingListLoaded: Bool {
        isSearchingMeetings ? isMeetingSearchLoaded : isMeetingListLoaded
    }

    var isDisplayedMeetingListLoadingMore: Bool {
        isSearchingMeetings ? isMeetingSearchLoadingMore : isMeetingListLoadingMore
    }

    var displayedMeetingListLoadError: String? {
        isSearchingMeetings ? meetingSearchLoadError : meetingListLoadError
    }

    var hasMoreDisplayedMeetings: Bool {
        isSearchingMeetings ? hasMoreMeetingSearchResults : hasMoreMeetings
    }

    var isDisplayedMeetingListLimited: Bool {
        isSearchingMeetings ? isMeetingSearchLimited : isMeetingListLimited
    }

    func startMeetingListObservation(dbQueue: DatabaseQueue, vaultId: UUID) {
        meetingListObservation?.cancel()
        meetingListObservationGeneration &+= 1
        let generation = meetingListObservationGeneration
        let observation = ValueObservation.tracking { db in
            try MeetingRepository.fetchMeetingSidebarPage(
                vaultId: vaultId,
                limit: Self.meetingPageSize,
                in: db
            )
        }
        .removeDuplicates()
        meetingListObservation = observation.start(
            in: dbQueue,
            onError: { [weak self] error in
                sidebarViewModelLogger.error("Failed to load meeting sidebar: \(error, privacy: .public)")
                ErrorReportingService.capture(error, context: ["source": "meetingSidebarObservation"])
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.meetingListObservationGeneration == generation else { return }
                self.isMeetingListLoaded = true
                self.isMeetingListLoadingMore = false
                self.meetingListLoadError = error.localizedDescription
            },
            onChange: { [weak self] page in
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.meetingListObservationGeneration == generation else { return }
                self.applyInitialMeetingPage(page)
            }
        )
    }

    func restartMeetingSearchIfNeeded(dbQueue: DatabaseQueue, vaultId: UUID) {
        guard !meetingSearchCriteria.isEmpty else { return }
        startMeetingSearch(
            dbQueue: dbQueue,
            vaultId: vaultId,
            criteria: meetingSearchCriteria,
            delay: nil,
            appending: false
        )
    }

    private func startMeetingSearch(
        dbQueue: DatabaseQueue,
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        delay: Duration?,
        appending: Bool
    ) {
        meetingSearchTask?.cancel()
        meetingSearchObservationGeneration &+= 1
        let generation = meetingSearchObservationGeneration
        let cursor = appending ? meetingSearchCursor : nil
        let searchQueue = searchDBQueue ?? dbQueue
        meetingSearchTask = Task { [weak self] in
            do {
                if let delay {
                    try await Task.sleep(for: delay)
                }
                let page = try await MeetingRepository.searchMeetingSidebarPage(
                    vaultId: vaultId,
                    criteria: criteria,
                    after: cursor,
                    limit: Self.meetingPageSize,
                    dbQueue: searchQueue
                )
                try Task.checkCancellation()
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.meetingSearchCriteria == criteria,
                      self.meetingSearchObservationGeneration == generation else { return }

                if appending, !page.replacesResults {
                    self.appendMeetingSearchPage(page)
                } else {
                    self.meetingSearchItems = page.items
                    self.meetingSearchGroups = page.groups
                    self.meetingSearchCursor = page.nextCursor
                    self.updateMeetingSearchBoundary(hasMore: page.hasMore)
                    self.isMeetingSearchLoaded = true
                    self.isMeetingSearchLoadingMore = false
                    self.meetingSearchLoadError = nil
                }
            } catch is CancellationError {
                return
            } catch {
                sidebarViewModelLogger.error("Failed to search meetings: \(error, privacy: .public)")
                ErrorReportingService.capture(error, context: ["source": "meetingSidebarSearch"])
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.meetingSearchCriteria == criteria,
                      self.meetingSearchObservationGeneration == generation else { return }
                self.isMeetingSearchLoaded = true
                self.isMeetingSearchLoadingMore = false
                self.meetingSearchLoadError = error.localizedDescription
            }
        }
    }

    func startSelectedMeetingObservationIfNeeded() {
        selectedMeetingObservation?.cancel()
        selectedMeetingObservationGeneration &+= 1
        selectedMeetingDetail = nil
        selectedMeetingDetailLoadError = nil
        guard let meetingId = selectedMeetingId,
              let dbQueue,
              let vaultId = currentVault?.id else { return }

        let generation = selectedMeetingObservationGeneration
        let observation = ValueObservation.tracking { db in
            try MeetingRepository.fetchMeetingDetail(
                id: meetingId,
                vaultId: vaultId,
                in: db
            )
        }
        .removeDuplicates()
        selectedMeetingObservation = observation.start(
            in: dbQueue,
            onError: { [weak self] error in
                sidebarViewModelLogger.error("Failed to load selected meeting: \(error, privacy: .public)")
                ErrorReportingService.capture(error, context: ["source": "selectedMeetingObservation"])
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.selectedMeetingId == meetingId,
                      self.selectedMeetingObservationGeneration == generation else { return }
                self.selectedMeetingDetailLoadError = error.localizedDescription
                self.lastError = error.localizedDescription
            },
            onChange: { [weak self] detail in
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.selectedMeetingId == meetingId,
                      self.selectedMeetingObservationGeneration == generation else { return }
                guard let detail else {
                    self.selectedMeetingIds.remove(meetingId)
                    return
                }
                self.selectedMeetingDetailLoadError = nil
                self.selectedMeetingDetail = detail
            }
        )
    }

    func startMeetingReferencesObservation(dbQueue: DatabaseQueue, vaultId: UUID) {
        meetingReferencesObservation?.cancel()
        meetingReferencesObservationGeneration &+= 1
        let generation = meetingReferencesObservationGeneration
        let observation = ValueObservation.tracking { db in
            try MeetingRepository.fetchMeetingReferences(vaultId: vaultId, in: db)
        }
        .removeDuplicates()
        meetingReferencesObservation = observation.start(
            in: dbQueue,
            onError: { [weak self] error in
                sidebarViewModelLogger.error("Failed to load meeting references: \(error, privacy: .public)")
                ErrorReportingService.capture(error, context: ["source": "meetingReferenceObservation"])
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.meetingReferencesObservationGeneration == generation else { return }
                self.isMeetingCatalogLoaded = false
            },
            onChange: { [weak self] references in
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.meetingReferencesObservationGeneration == generation else { return }
                let removedIds = Set(self.meetingReferences.map(\.id))
                    .subtracting(references.map(\.id))
                self.meetingReferences = references
                self.isMeetingCatalogLoaded = true
                if !removedIds.isEmpty {
                    self.selectedMeetingIds.subtract(removedIds)
                }
            }
        )
    }

    func loadMeetingReferencesIfNeeded() {
        guard !isMeetingCatalogRequested,
              let dbQueue,
              let vaultId = currentVault?.id else { return }
        isMeetingCatalogRequested = true
        startMeetingReferencesObservation(dbQueue: dbQueue, vaultId: vaultId)
    }

    func resetMeetingListPagination() {
        meetingPageLoadTask?.cancel()
        meetingPageLoadGeneration &+= 1
        additionalMeetingRowsObservation?.cancel()
        additionalMeetingRowsObservationGeneration &+= 1
        meetingSidebarItems.removeAll()
        meetingSidebarGroups.removeAll()
        meetingInitialPageIDs.removeAll()
        meetingListCursor = nil
        hasMoreMeetings = false
        isMeetingListLimited = false
        isMeetingListLoaded = false
        isMeetingListLoadingMore = false
        meetingListLoadError = nil
    }

    func updateCachedMeetingName(id: UUID, name: String) {
        updateCachedMeetingItems(id: id) { item in
            item.meetingName = name
        }
        restartCurrentMeetingSearch()
    }

    func updateCachedMeetingProject(id: UUID, projectId: UUID?, projectName: String?) {
        updateCachedMeetingItems(id: id) { item in
            item.projectId = projectId
            item.projectName = projectName
        }
    }

    func removeCachedMeetings(ids: Set<UUID>) {
        meetingSidebarItems.removeAll { ids.contains($0.id) }
        meetingSearchItems.removeAll { ids.contains($0.id) }
        meetingSidebarGroups = MeetingDateGrouping.groups(from: meetingSidebarItems)
        refreshMeetingSearchGroups()
        startAdditionalMeetingRowsObservationIfNeeded()
    }

    func restartCurrentMeetingSearch() {
        guard let dbQueue,
              let vaultId = currentVault?.id else { return }
        restartMeetingSearchIfNeeded(dbQueue: dbQueue, vaultId: vaultId)
    }

    func updateMeetingSearchQuery(_ value: String) {
        updateMeetingSearchCriteria(MeetingSearchCriteria(text: value))
    }

    func updateMeetingSearchCriteria(_ criteria: MeetingSearchCriteria) {
        guard criteria != meetingSearchCriteria else { return }

        meetingSearchTask?.cancel()
        meetingSearchObservationGeneration &+= 1
        meetingSearchCriteria = criteria
        meetingSearchItems.removeAll()
        meetingSearchGroups.removeAll()
        meetingSearchLoadError = nil
        hasMoreMeetingSearchResults = false
        meetingSearchCursor = nil
        isMeetingSearchLimited = false

        guard !criteria.isEmpty else {
            isMeetingSearchLoaded = true
            isMeetingSearchLoadingMore = false
            return
        }

        isMeetingSearchLoaded = false
        isMeetingSearchLoadingMore = false
        guard let dbQueue,
              let vaultId = currentVault?.id else { return }
        startMeetingSearch(
            dbQueue: dbQueue,
            vaultId: vaultId,
            criteria: criteria,
            delay: .milliseconds(250),
            appending: false
        )
    }

    func loadMoreDisplayedMeetings() {
        guard hasMoreDisplayedMeetings,
              !isDisplayedMeetingListLoadingMore,
              displayedMeetingListLoadError == nil,
              let dbQueue,
              let vaultId = currentVault?.id else { return }

        if isSearchingMeetings {
            isMeetingSearchLoadingMore = true
            startMeetingSearch(
                dbQueue: dbQueue,
                vaultId: vaultId,
                criteria: meetingSearchCriteria,
                delay: nil,
                appending: true
            )
        } else {
            isMeetingListLoadingMore = true
            loadNextMeetingPage(dbQueue: dbQueue, vaultId: vaultId)
        }
    }

    func retryDisplayedMeetingLoading() {
        guard let dbQueue,
              let vaultId = currentVault?.id else { return }

        if isSearchingMeetings {
            let hasItems = !meetingSearchItems.isEmpty
            meetingSearchLoadError = nil
            if hasItems {
                isMeetingSearchLoadingMore = true
            } else {
                isMeetingSearchLoaded = false
            }
            startMeetingSearch(
                dbQueue: dbQueue,
                vaultId: vaultId,
                criteria: meetingSearchCriteria,
                delay: nil,
                appending: hasItems
            )
        } else {
            let hasItems = !meetingSidebarItems.isEmpty
            meetingListLoadError = nil
            if hasItems {
                isMeetingListLoadingMore = true
            } else {
                isMeetingListLoaded = false
            }
            if hasItems {
                loadNextMeetingPage(dbQueue: dbQueue, vaultId: vaultId)
            } else {
                startMeetingListObservation(dbQueue: dbQueue, vaultId: vaultId)
            }
        }
    }

    private func applyInitialMeetingPage(_ page: MeetingSidebarPage) {
        let pageIDs = page.items.map(\.id)
        let hasStableBoundary = !meetingInitialPageIDs.isEmpty && pageIDs == meetingInitialPageIDs

        if hasStableBoundary, meetingSidebarItems.count >= meetingInitialPageIDs.count {
            meetingSidebarItems.replaceSubrange(
                0 ..< meetingInitialPageIDs.count,
                with: page.items
            )
        } else {
            meetingPageLoadTask?.cancel()
            meetingPageLoadGeneration &+= 1
            meetingSidebarItems = page.items
            meetingListCursor = page.nextCursor
            isMeetingListLimited = false
        }

        meetingInitialPageIDs = pageIDs
        meetingSidebarGroups = MeetingDateGrouping.groups(from: meetingSidebarItems)
        if !hasStableBoundary || meetingSidebarItems.count == page.items.count {
            updateMeetingListBoundary(hasMore: page.hasMore)
        }
        isMeetingListLoaded = true
        isMeetingListLoadingMore = false
        meetingListLoadError = nil
        startAdditionalMeetingRowsObservationIfNeeded()
    }

    private func loadNextMeetingPage(dbQueue: DatabaseQueue, vaultId: UUID) {
        guard let cursor = meetingListCursor else {
            isMeetingListLoadingMore = false
            hasMoreMeetings = false
            return
        }

        meetingPageLoadTask?.cancel()
        meetingPageLoadGeneration &+= 1
        let generation = meetingPageLoadGeneration
        meetingPageLoadTask = Task { [weak self] in
            do {
                let fetchTask = Task.detached(priority: .userInitiated) {
                    try dbQueue.read { db in
                        try MeetingRepository.fetchMeetingSidebarPage(
                            vaultId: vaultId,
                            after: cursor,
                            limit: Self.meetingPageSize,
                            in: db
                        )
                    }
                }
                let page = try await withTaskCancellationHandler {
                    try await fetchTask.value
                } onCancel: {
                    fetchTask.cancel()
                }
                try Task.checkCancellation()
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.meetingPageLoadGeneration == generation,
                      self.meetingListCursor == cursor else { return }
                self.meetingSidebarItems.append(contentsOf: page.items)
                self.meetingSidebarGroups = MeetingDateGrouping.groups(from: self.meetingSidebarItems)
                self.meetingListCursor = page.nextCursor
                self.updateMeetingListBoundary(hasMore: page.hasMore)
                self.isMeetingListLoadingMore = false
                self.meetingListLoadError = nil
                self.startAdditionalMeetingRowsObservationIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                sidebarViewModelLogger.error("Failed to load more meetings: \(error, privacy: .public)")
                ErrorReportingService.capture(error, context: ["source": "meetingSidebarPage"])
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.meetingPageLoadGeneration == generation else { return }
                self.isMeetingListLoadingMore = false
                self.meetingListLoadError = error.localizedDescription
            }
        }
    }

    private func appendMeetingSearchPage(_ page: MeetingSearchPage) {
        meetingSearchItems.append(contentsOf: page.items)
        refreshMeetingSearchGroups()
        meetingSearchCursor = page.nextCursor
        updateMeetingSearchBoundary(hasMore: page.hasMore)
        isMeetingSearchLoaded = true
        isMeetingSearchLoadingMore = false
        meetingSearchLoadError = nil
    }

    private func startAdditionalMeetingRowsObservationIfNeeded() {
        additionalMeetingRowsObservation?.cancel()
        additionalMeetingRowsObservationGeneration &+= 1

        let ids = Array(meetingSidebarItems.dropFirst(meetingInitialPageIDs.count).map(\.id))
        guard !ids.isEmpty,
              let dbQueue,
              let vaultId = currentVault?.id else { return }

        let generation = additionalMeetingRowsObservationGeneration
        let observedIDs = Set(ids)
        let observation = ValueObservation.tracking { db in
            try MeetingRepository.fetchMeetingSidebarItems(
                ids: ids,
                vaultId: vaultId,
                in: db
            )
        }
        .removeDuplicates()
        additionalMeetingRowsObservation = observation.start(
            in: dbQueue,
            onError: { error in
                sidebarViewModelLogger.error(
                    "Failed to refresh additional meeting rows: \(error, privacy: .public)"
                )
                ErrorReportingService.capture(
                    error,
                    context: ["source": "additionalMeetingRowsObservation"]
                )
            },
            onChange: { [weak self] items in
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.additionalMeetingRowsObservationGeneration == generation else { return }

                let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
                self.meetingSidebarItems.removeAll {
                    observedIDs.contains($0.id) && itemsByID[$0.id] == nil
                }
                for index in self.meetingSidebarItems.indices {
                    guard let item = itemsByID[self.meetingSidebarItems[index].id] else { continue }
                    self.meetingSidebarItems[index] = item
                }
                self.meetingSidebarGroups = MeetingDateGrouping.groups(from: self.meetingSidebarItems)
            }
        )
    }

    private func updateMeetingListBoundary(hasMore: Bool) {
        isMeetingListLimited = hasMore && meetingSidebarItems.count >= Self.maximumVisibleMeetings
        hasMoreMeetings = hasMore && !isMeetingListLimited
    }

    private func updateMeetingSearchBoundary(hasMore: Bool) {
        isMeetingSearchLimited = hasMore && meetingSearchItems.count >= Self.maximumVisibleMeetings
        hasMoreMeetingSearchResults = hasMore && !isMeetingSearchLimited
    }

    private func updateCachedMeetingItems(
        id: UUID,
        update: (inout MeetingSidebarItem) -> Void
    ) {
        if let index = meetingSidebarItems.firstIndex(where: { $0.id == id }) {
            update(&meetingSidebarItems[index])
            meetingSidebarGroups = MeetingDateGrouping.groups(from: meetingSidebarItems)
        }
        if let index = meetingSearchItems.firstIndex(where: { $0.id == id }) {
            update(&meetingSearchItems[index])
            refreshMeetingSearchGroups()
        }
    }

    private func refreshMeetingSearchGroups() {
        if meetingSearchCriteria.text.isEmpty {
            meetingSearchGroups = MeetingDateGrouping.groups(from: meetingSearchItems)
        } else {
            meetingSearchGroups = MeetingDateGrouping.searchResultGroups(from: meetingSearchItems)
        }
    }

    func meetingSidebarItem(id: UUID) -> MeetingSidebarItem? {
        if let item = meetingSidebarItems.first(where: { $0.meetingId == id }) {
            return item
        }
        if let item = meetingSearchItems.first(where: { $0.meetingId == id }) {
            return item
        }
        guard let selectedMeetingDetail,
              selectedMeetingDetail.meetingId == id else { return nil }
        return MeetingSidebarItem(detail: selectedMeetingDetail)
    }

    var selectedMeetingOutsideDisplayedItems: MeetingSidebarItem? {
        guard let selectedMeetingId,
              !displayedMeetingItems.contains(where: { $0.meetingId == selectedMeetingId }),
              let selectedMeetingDetail else { return nil }
        return MeetingSidebarItem(detail: selectedMeetingDetail)
    }
}

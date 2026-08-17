import Foundation
import GRDB

extension SidebarViewModel {
    nonisolated static let projectMeetingInitialLimit = 5
    nonisolated static let projectMeetingPageSize = 10

    var projectMeetingGroups: [MeetingProjectGroup] {
        var groups = allProjectItems.map { project in
            projectMeetingGroup(key: .project(project.projectId), project: project)
        }
        groups.sort(by: projectMeetingGroupComesFirst)
        if projectMeetingUnassignedCount > 0 {
            groups.append(projectMeetingGroup(key: .unassigned, project: nil))
        }
        return groups
    }

    func setProjectMeetingProjectionNeeded(_ isNeeded: Bool) {
        guard isProjectMeetingProjectionRequested != isNeeded else { return }
        isProjectMeetingProjectionRequested = isNeeded
        guard isNeeded else {
            projectMeetingObservation?.cancel()
            projectMeetingObservation = nil
            projectMeetingObservationGeneration &+= 1
            cancelProjectMeetingPageLoads()
            projectMeetingItemsByKey.removeAll()
            projectMeetingHasMoreByKey.removeAll()
            projectMeetingLoadErrors.removeAll()
            projectMeetingLimitedKeys.removeAll()
            isProjectMeetingProjectionLoaded = false
            isProjectMeetingProjectionLimited = false
            projectMeetingProjectionLoadError = nil
            projectMeetingUnassignedCount = 0
            return
        }
        guard let dbQueue, let vaultId = currentVault?.id else { return }
        startProjectMeetingObservation(dbQueue: dbQueue, vaultId: vaultId)
    }

    func startProjectMeetingObservation(dbQueue: DatabaseQueue, vaultId: UUID) {
        projectMeetingObservation?.cancel()
        projectMeetingObservationGeneration &+= 1
        let generation = projectMeetingObservationGeneration
        let expandedLimits = projectMeetingItemsByKey.compactMapValues { items in
            items.count > Self.projectMeetingInitialLimit ? items.count : nil
        }
        let observation = ValueObservation.tracking { db in
            try MeetingRepository.fetchMeetingProjectProjection(
                vaultId: vaultId,
                recentLimit: Self.projectMeetingInitialLimit,
                expandedLimits: expandedLimits,
                totalLimit: Self.maximumVisibleMeetings,
                in: db
            )
        }
        .removeDuplicates()
        projectMeetingObservation = observation.start(
            in: dbQueue,
            onError: { [weak self] error in
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.projectMeetingObservationGeneration == generation else { return }
                self.isProjectMeetingProjectionLoaded = true
                self.projectMeetingProjectionLoadError = error.localizedDescription
            },
            onChange: { [weak self] projection in
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.projectMeetingObservationGeneration == generation else { return }
                self.applyProjectMeetingProjection(projection)
            }
        )
    }

    func retryProjectMeetingProjection() {
        guard let dbQueue, let vaultId = currentVault?.id else { return }
        isProjectMeetingProjectionLoaded = false
        projectMeetingProjectionLoadError = nil
        startProjectMeetingObservation(dbQueue: dbQueue, vaultId: vaultId)
    }

    func cancelProjectMeetingPageLoads() {
        projectMeetingLoadTasks.values.forEach { $0.cancel() }
        projectMeetingLoadTasks.removeAll()
        projectMeetingLoadingKeys.removeAll()
        for key in Array(projectMeetingLoadGenerations.keys) {
            projectMeetingLoadGenerations[key, default: 0] += 1
        }
    }

    func loadMoreProjectMeetings(key: MeetingProjectKey) {
        if projectMeetingProjectionLoadError != nil {
            retryProjectMeetingProjection()
            return
        }
        guard projectMeetingHasMoreByKey[key] == true,
              !projectMeetingLoadingKeys.contains(key),
              !projectMeetingLimitedKeys.contains(key),
              let cursor = projectMeetingItemsByKey[key]?.last.map(MeetingSidebarCursor.init),
              let dbQueue,
              let vaultId = currentVault?.id else { return }

        projectMeetingLoadTasks[key]?.cancel()
        let generation = projectMeetingLoadGenerations[key, default: 0] + 1
        projectMeetingLoadGenerations[key] = generation
        projectMeetingLoadingKeys.insert(key)
        projectMeetingLoadErrors[key] = nil
        projectMeetingLoadTasks[key] = Task { [weak self] in
            do {
                let fetchTask = Task.detached(priority: .userInitiated) {
                    try dbQueue.read { db in
                        try MeetingRepository.fetchMeetingProjectPage(
                            key: key,
                            vaultId: vaultId,
                            after: cursor,
                            limit: Self.projectMeetingPageSize,
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
                      self.projectMeetingLoadGenerations[key] == generation else { return }
                var items = self.projectMeetingItemsByKey[key, default: []]
                let totalVisibleCount = self.projectMeetingItemsByKey.values.reduce(0) { $0 + $1.count }
                let remaining = max(Self.maximumVisibleMeetings - totalVisibleCount, 0)
                let omittedByLimit = page.items.count > remaining
                items.append(contentsOf: page.items.prefix(remaining))
                self.projectMeetingItemsByKey[key] = items
                let isLimited = (page.hasMore || omittedByLimit)
                    && totalVisibleCount + min(page.items.count, remaining) >= Self.maximumVisibleMeetings
                self.projectMeetingHasMoreByKey[key] = page.hasMore && !isLimited
                if isLimited {
                    self.projectMeetingLimitedKeys.insert(key)
                } else {
                    self.projectMeetingLimitedKeys.remove(key)
                }
                if totalVisibleCount + min(page.items.count, remaining) >= Self.maximumVisibleMeetings {
                    let keysWithMore = self.projectMeetingHasMoreByKey.compactMap { $0.value ? $0.key : nil }
                    if !keysWithMore.isEmpty || isLimited {
                        self.isProjectMeetingProjectionLimited = true
                        self.projectMeetingLimitedKeys.formUnion(keysWithMore)
                        for keyWithMore in keysWithMore {
                            self.projectMeetingHasMoreByKey[keyWithMore] = false
                        }
                    }
                }
                self.projectMeetingLoadingKeys.remove(key)
                self.startProjectMeetingObservation(dbQueue: dbQueue, vaultId: vaultId)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.currentVault?.id == vaultId,
                      self.projectMeetingLoadGenerations[key] == generation else { return }
                self.projectMeetingLoadingKeys.remove(key)
                self.projectMeetingLoadErrors[key] = error.localizedDescription
            }
        }
    }

    private func applyProjectMeetingProjection(
        _ projection: MeetingProjectProjection
    ) {
        let knownKeys = Set(projectMeetingItemsByKey.keys).union(projection.itemsByKey.keys)
        projectMeetingLimitedKeys = projection.truncatedKeys
        if projection.isLimited {
            projectMeetingLimitedKeys.formUnion(projection.hasMoreKeys)
        }
        for key in knownKeys {
            projectMeetingItemsByKey[key] = projection.itemsByKey[key, default: []]
            projectMeetingHasMoreByKey[key] = projection.hasMoreKeys.contains(key)
                && !projectMeetingLimitedKeys.contains(key)
        }
        isProjectMeetingProjectionLimited = projection.isLimited
        projectMeetingUnassignedCount = projection.unassignedMeetingCount
        isProjectMeetingProjectionLoaded = true
        projectMeetingProjectionLoadError = nil
    }

    private func projectMeetingGroup(
        key: MeetingProjectKey,
        project: ProjectOverviewItem?
    ) -> MeetingProjectGroup {
        let meetings = projectMeetingItemsByKey[key, default: []]
        let meetingCount = project?.meetingCount ?? projectMeetingUnassignedCount
        let isLimited = projectMeetingLimitedKeys.contains(key)
            || (isProjectMeetingProjectionLimited && meetingCount > meetings.count)
        return MeetingProjectGroup(
            key: key,
            project: project,
            meetings: meetings,
            hasMore: projectMeetingHasMoreByKey[key] == true && !isLimited,
            isLoadingMore: !isProjectMeetingProjectionLoaded || projectMeetingLoadingKeys.contains(key),
            loadError: projectMeetingProjectionLoadError ?? projectMeetingLoadErrors[key],
            isLimited: isLimited
        )
    }

    private func projectMeetingGroupComesFirst(
        _ lhs: MeetingProjectGroup,
        _ rhs: MeetingProjectGroup
    ) -> Bool {
        let lhsName = lhs.project?.projectName ?? ""
        let rhsName = rhs.project?.projectName ?? ""
        let comparison = lhsName.localizedStandardCompare(rhsName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return String(describing: lhs.key) < String(describing: rhs.key)
    }
}

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
        if projectMeetingItemsByKey[.unassigned]?.isEmpty == false {
            groups.append(projectMeetingGroup(key: .unassigned, project: nil))
        }
        return groups
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
                let remaining = max(Self.maximumVisibleMeetings - items.count, 0)
                let omittedByLimit = page.items.count > remaining
                items.append(contentsOf: page.items.prefix(remaining))
                self.projectMeetingItemsByKey[key] = items
                let isLimited = (page.hasMore || omittedByLimit)
                    && items.count >= Self.maximumVisibleMeetings
                self.projectMeetingHasMoreByKey[key] = page.hasMore && !isLimited
                if isLimited {
                    self.projectMeetingLimitedKeys.insert(key)
                } else {
                    self.projectMeetingLimitedKeys.remove(key)
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
        _ projection: [MeetingProjectKey: [MeetingSidebarItem]]
    ) {
        let knownKeys = Set(projectMeetingItemsByKey.keys).union(projection.keys)
        for key in knownKeys {
            let projectedItems = projection[key, default: []]
            let visibleCount = max(
                projectMeetingItemsByKey[key]?.count ?? 0,
                Self.projectMeetingInitialLimit
            )
            projectMeetingItemsByKey[key] = Array(projectedItems.prefix(visibleCount))
            projectMeetingHasMoreByKey[key] = projectedItems.count > visibleCount
                && !projectMeetingLimitedKeys.contains(key)
        }
        isProjectMeetingProjectionLoaded = true
        projectMeetingProjectionLoadError = nil
    }

    private func projectMeetingGroup(
        key: MeetingProjectKey,
        project: ProjectOverviewItem?
    ) -> MeetingProjectGroup {
        MeetingProjectGroup(
            key: key,
            project: project,
            meetings: projectMeetingItemsByKey[key, default: []],
            hasMore: projectMeetingHasMoreByKey[key] == true,
            isLoadingMore: !isProjectMeetingProjectionLoaded || projectMeetingLoadingKeys.contains(key),
            loadError: projectMeetingProjectionLoadError ?? projectMeetingLoadErrors[key],
            isLimited: projectMeetingLimitedKeys.contains(key)
        )
    }

    private func projectMeetingGroupComesFirst(
        _ lhs: MeetingProjectGroup,
        _ rhs: MeetingProjectGroup
    ) -> Bool {
        let lhsLatest = lhs.project?.latestMeetingDate ?? lhs.meetings.first?.effectiveRecordingStartedAt
        let rhsLatest = rhs.project?.latestMeetingDate ?? rhs.meetings.first?.effectiveRecordingStartedAt
        if lhsLatest != rhsLatest {
            return lhsLatest.map { lhsDate in rhsLatest.map { lhsDate > $0 } ?? true } ?? false
        }
        let lhsCreatedAt = lhs.project?.createdAt ?? .distantPast
        let rhsCreatedAt = rhs.project?.createdAt ?? .distantPast
        if lhsCreatedAt != rhsCreatedAt { return lhsCreatedAt > rhsCreatedAt }
        return String(describing: lhs.key) < String(describing: rhs.key)
    }
}

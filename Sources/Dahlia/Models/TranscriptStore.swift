import Combine
import Foundation
import SwiftUI

// swiftlint:disable file_length
/// SwiftUI に公開する、再読込可能で有界な文字起こし projection。
/// 確定文字起こしの正本は SQLite であり、この store は viewport 周辺だけを保持する。
@MainActor
final class TranscriptStore: ObservableObject { // swiftlint:disable:this type_body_length
    nonisolated static let initialPageSize = 200
    nonisolated static let pageSize = 100
    nonisolated static let maximumConfirmedSegmentCount = 300

    private enum UnconfirmedMutation {
        case clear
        case upsert(TranscriptSegment)
    }

    private enum FailedPageLoad {
        case earlier
        case later
        case latest
    }

    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var recordingSessions: [RecordingSessionTimeline] = []
    @Published private(set) var hasEarlierSegments = false
    @Published private(set) var hasLaterSegments = false
    @Published private(set) var isLoadingInitialPage = false
    @Published private(set) var isLoadingPage = false
    @Published private(set) var pageLoadError: String?
    @Published private(set) var hasNewerSegments = false
    @Published private(set) var requiresFullMeetingReload = false

    var recordingStartTime: Date?

    var timeBase: Date {
        recordingStartTime ?? recordingSessions.first?.startedAt ?? segments.first?.startTime ?? Date()
    }

    var latestConfirmedID: TranscriptSegment.ID? {
        segments.last(where: \.isConfirmed)?.id
    }

    var confirmedSegmentCount: Int {
        segments.lazy.filter(\.isConfirmed).count
    }

    private var meetingId: UUID?
    private var pageLoader: TranscriptPageLoader?
    private var pagingGeneration = 0
    private var projectionRevision = 0
    private var isFollowingLatest = true
    private var failedPageLoad: FailedPageLoad?
    private var pendingLatestReloadWaiters: [CheckedContinuation<Bool, Never>] = []
    private var deferredConfirmedSegments: [UUID: TranscriptSegment] = [:]

    // MARK: - Unconfirmed Segment Throttle (per source)

    private var unconfirmedThrottleTasks: [String: Task<Void, Never>] = [:]
    private var pendingUnconfirmed: [String: UnconfirmedMutation] = [:]
    private var lastUnconfirmedUpdate: [String: ContinuousClock.Instant] = [:]
    private let throttleInterval: Duration = .milliseconds(200)

    func prepareForMeetingLoading(meetingId: UUID, loader: TranscriptPageLoader) {
        cancelPendingLatestReloads()
        pagingGeneration &+= 1
        self.meetingId = meetingId
        self.pageLoader = loader
        segments.removeAll()
        hasEarlierSegments = false
        hasLaterSegments = false
        hasNewerSegments = false
        pageLoadError = nil
        requiresFullMeetingReload = false
        failedPageLoad = nil
        isLoadingPage = true
        isLoadingInitialPage = true
        isFollowingLatest = true
        deferredConfirmedSegments.removeAll()
    }

    func attachPagingContext(meetingId: UUID, loader: TranscriptPageLoader) {
        let meetingChanged = self.meetingId != meetingId
        cancelPendingLatestReloads()
        pagingGeneration &+= 1
        self.meetingId = meetingId
        self.pageLoader = loader
        isLoadingPage = false
        isLoadingInitialPage = false
        if meetingChanged {
            deferredConfirmedSegments.removeAll()
        }
    }

    func failInitialMeetingLoad(_ error: Error) {
        isLoadingPage = false
        isLoadingInitialPage = false
        pageLoadError = error.localizedDescription
        failedPageLoad = nil
        requiresFullMeetingReload = true
    }

    func configurePaging(
        meetingId: UUID,
        loader: TranscriptPageLoader,
        initialPage: TranscriptPage
    ) {
        cancelPendingLatestReloads()
        pagingGeneration &+= 1
        self.meetingId = meetingId
        self.pageLoader = loader
        isFollowingLatest = true
        failedPageLoad = nil
        pageLoadError = nil
        requiresFullMeetingReload = false
        hasNewerSegments = false
        isLoadingPage = false
        isLoadingInitialPage = false
        applyLatestPage(initialPage)
    }

    func setFollowingLatest(_ followsLatest: Bool) {
        isFollowingLatest = followsLatest
        if followsLatest, !hasLaterSegments {
            hasNewerSegments = false
        }
    }

    @discardableResult
    func loadEarlier() async -> Bool {
        guard hasEarlierSegments,
              let cursor = confirmedSegments.first.map(TranscriptPageCursor.init(segment:))
        else { return false }
        return await loadPage(.before(cursor), failure: .earlier)
    }

    @discardableResult
    func loadLater() async -> Bool {
        guard hasLaterSegments,
              let cursor = confirmedSegments.last.map(TranscriptPageCursor.init(segment:))
        else { return false }
        return await loadPage(.after(cursor), failure: .later)
    }

    @discardableResult
    func reloadLatest() async -> Bool {
        await requestLatestReload()
    }

    @discardableResult
    func reloadLatestAfterUICompaction() async -> Bool {
        clearAllUnconfirmedSegmentsImmediately()
        return await requestLatestReload()
    }

    @discardableResult
    func retryPageLoad() async -> Bool {
        switch failedPageLoad {
        case .earlier:
            await loadEarlier()
        case .later:
            await loadLater()
        case .latest:
            await reloadLatest()
        case nil:
            false
        }
    }

    func addSegment(_ segment: TranscriptSegment) {
        projectionRevision &+= 1
        guard segment.isConfirmed else {
            insertInTimeline(segment)
            return
        }

        guard isFollowingLatest, !hasLaterSegments else {
            deferredConfirmedSegments[segment.id] = segment
            trimDeferredConfirmedSegments()
            hasLaterSegments = true
            hasNewerSegments = true
            return
        }

        insertInTimeline(segment)
        let removed = trimConfirmedSegments(keeping: .latest)
        hasEarlierSegments = hasEarlierSegments || removed
    }

    /// previewを同期的に取り除いてから確定セグメントを追加し、SwiftUI上の重複IDを防ぐ。
    func finalizeSegment(_ segment: TranscriptSegment, forSource sourceLabel: String? = nil) {
        clearUnconfirmedSegmentsImmediately(forSource: sourceLabel)
        addSegment(segment)
    }

    /// 指定ソースの未確定セグメントを更新する。
    /// 200ms 以内の連続呼び出しはスロットルし、最後の状態のみ反映する。
    @discardableResult
    func updateUnconfirmedSegment(_ segment: TranscriptSegment, forSource sourceLabel: String? = nil) -> TranscriptSegment {
        let mergedSegment = mergedUnconfirmedSegment(segment, forSource: sourceLabel)
        scheduleUnconfirmedMutation(.upsert(mergedSegment), forSource: sourceLabel)
        return mergedSegment
    }

    func clearUnconfirmedSegments(forSource sourceLabel: String? = nil) {
        scheduleUnconfirmedMutation(.clear, forSource: sourceLabel)
    }

    /// DB 以外の既存呼び出し向け。入力が大きくても projection の上限を超えて保持しない。
    func loadSegments(_ newSegments: [TranscriptSegment]) {
        projectionRevision &+= 1
        let previews = latestPreviews(in: newSegments)
        let confirmed = newSegments.filter(\.isConfirmed).sorted(by: Self.precedes)
        let boundedConfirmed = confirmed.suffix(Self.maximumConfirmedSegmentCount)
        segments = (Array(boundedConfirmed) + previews).sorted(by: Self.precedes)
        hasEarlierSegments = confirmed.count > boundedConfirmed.count
        hasLaterSegments = false
        hasNewerSegments = false
        isFollowingLatest = true
        deferredConfirmedSegments.removeAll()
    }

    func loadRecordingSessions(_ sessions: [RecordingSessionTimeline]) {
        recordingSessions = sessions.sorted { lhs, rhs in
            if lhs.offsetSeconds == rhs.offsetSeconds {
                return lhs.startedAt < rhs.startedAt
            }
            return lhs.offsetSeconds < rhs.offsetSeconds
        }
    }

    func upsertRecordingSession(_ session: RecordingSessionTimeline) {
        if let index = recordingSessions.firstIndex(where: { $0.id == session.id }) {
            recordingSessions[index] = session
        } else {
            recordingSessions.append(session)
        }
        loadRecordingSessions(recordingSessions)
    }

    func updateTranslatedText(for segmentID: UUID, translatedText: String?) {
        var didUpdate = false
        if var deferred = deferredConfirmedSegments[segmentID] {
            if deferred.translatedText != translatedText {
                deferred.translatedText = translatedText
                deferredConfirmedSegments[segmentID] = deferred
                didUpdate = true
            }
        }
        if let index = segments.firstIndex(where: { $0.id == segmentID }),
           segments[index].translatedText != translatedText {
            segments[index].translatedText = translatedText
            didUpdate = true
        }
        if didUpdate {
            projectionRevision &+= 1
        }
    }

    func clear() {
        cancelPendingLatestReloads()
        pagingGeneration &+= 1
        projectionRevision &+= 1
        meetingId = nil
        pageLoader = nil
        segments.removeAll()
        recordingSessions.removeAll()
        recordingStartTime = nil
        hasEarlierSegments = false
        hasLaterSegments = false
        isLoadingInitialPage = false
        isLoadingPage = false
        pageLoadError = nil
        requiresFullMeetingReload = false
        hasNewerSegments = false
        failedPageLoad = nil
        isFollowingLatest = true
        deferredConfirmedSegments.removeAll()
        unconfirmedThrottleTasks.values.forEach { $0.cancel() }
        unconfirmedThrottleTasks.removeAll()
        pendingUnconfirmed.removeAll()
        lastUnconfirmedUpdate.removeAll()
    }

    private var confirmedSegments: [TranscriptSegment] {
        segments.filter(\.isConfirmed)
    }

    private func requestLatestReload() async -> Bool {
        guard meetingId != nil, pageLoader != nil else { return false }
        if isLoadingPage {
            hasNewerSegments = true
            return await withCheckedContinuation { continuation in
                pendingLatestReloadWaiters.append(continuation)
            }
        }
        return await loadPage(.latest, failure: .latest)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func loadPage(
        _ direction: TranscriptPageDirection,
        failure: FailedPageLoad
    ) async -> Bool {
        guard !isLoadingPage,
              let meetingId,
              let pageLoader else { return false }

        let generation = pagingGeneration
        let revision = projectionRevision
        isLoadingPage = true
        if case .latest = direction, segments.isEmpty {
            isLoadingInitialPage = true
        }
        pageLoadError = nil
        failedPageLoad = nil
        let didLoad: Bool
        do {
            let limit = if case .latest = direction {
                Self.initialPageSize
            } else {
                Self.pageSize
            }
            let page = try await pageLoader.load(
                meetingId: meetingId,
                direction: direction,
                limit: limit
            )
            if generation == pagingGeneration, self.meetingId == meetingId {
                let projectionChangedDuringLoad = revision != projectionRevision

                switch direction {
                case .latest:
                    applyLatestPage(page, preservingExistingProjection: projectionChangedDuringLoad)
                case .before:
                    mergeEarlierPage(page, preservingExistingProjection: projectionChangedDuringLoad)
                case .after:
                    mergeLaterPage(page, preservingExistingProjection: projectionChangedDuringLoad)
                }
                didLoad = true
            } else {
                didLoad = false
            }
        } catch is CancellationError {
            didLoad = false
        } catch {
            if generation == pagingGeneration {
                pageLoadError = error.localizedDescription
                failedPageLoad = failure
            }
            didLoad = false
        }

        if generation == pagingGeneration {
            isLoadingPage = false
            isLoadingInitialPage = false
            await performPendingLatestReloadIfNeeded()
        }
        return didLoad
    }

    private func applyLatestPage(
        _ page: TranscriptPage,
        preservingExistingProjection: Bool = false
    ) {
        let previews = segments.filter { !$0.isConfirmed }
        var confirmedById = Dictionary(uniqueKeysWithValues: page.segments.map { ($0.id, $0) })
        if preservingExistingProjection {
            for segment in segments where segment.isConfirmed {
                confirmedById[segment.id] = segment
            }
        }
        for segment in deferredConfirmedSegments.values {
            confirmedById[segment.id] = segment
        }
        deferredConfirmedSegments.removeAll()
        segments = (Array(confirmedById.values) + previews).sorted(by: Self.precedes)
        let removed = trimConfirmedSegments(keeping: .latest)
        hasEarlierSegments = page.hasEarlier || removed
        hasLaterSegments = false
        hasNewerSegments = false
        isFollowingLatest = true
    }

    private func mergeEarlierPage(
        _ page: TranscriptPage,
        preservingExistingProjection: Bool
    ) {
        mergeConfirmedSegments(page.segments, preservingExistingProjection: preservingExistingProjection)
        let removed = trimConfirmedSegments(keeping: .earliest)
        hasEarlierSegments = page.hasEarlier
        hasLaterSegments = hasLaterSegments || page.hasLater || removed
        isFollowingLatest = false
    }

    private func mergeLaterPage(
        _ page: TranscriptPage,
        preservingExistingProjection: Bool
    ) {
        mergeConfirmedSegments(page.segments, preservingExistingProjection: preservingExistingProjection)
        let removed = trimConfirmedSegments(keeping: .latest)
        hasEarlierSegments = hasEarlierSegments || page.hasEarlier || removed
        hasLaterSegments = page.hasLater
        if !hasLaterSegments {
            hasNewerSegments = false
        }
    }

    private func mergeConfirmedSegments(
        _ incoming: [TranscriptSegment],
        preservingExistingProjection: Bool
    ) {
        var byId = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        for segment in incoming where segment.isConfirmed {
            if !preservingExistingProjection || byId[segment.id] == nil {
                byId[segment.id] = segment
            }
        }
        segments = byId.values.sorted(by: Self.precedes)
    }

    private func performPendingLatestReloadIfNeeded() async {
        guard !pendingLatestReloadWaiters.isEmpty else { return }
        let waiters = pendingLatestReloadWaiters
        pendingLatestReloadWaiters.removeAll()
        let result = await loadPage(.latest, failure: .latest)
        waiters.forEach { $0.resume(returning: result) }
    }

    private func cancelPendingLatestReloads() {
        let waiters = pendingLatestReloadWaiters
        pendingLatestReloadWaiters.removeAll()
        waiters.forEach { $0.resume(returning: false) }
    }

    private func trimDeferredConfirmedSegments() {
        guard deferredConfirmedSegments.count > Self.maximumConfirmedSegmentCount else { return }
        let ordered = deferredConfirmedSegments.values.sorted(by: Self.precedes)
        let retained = ordered.suffix(Self.maximumConfirmedSegmentCount)
        deferredConfirmedSegments = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
    }

    private enum RetainedEdge {
        case earliest
        case latest
    }

    @discardableResult
    private func trimConfirmedSegments(keeping edge: RetainedEdge) -> Bool {
        let confirmed = segments.filter(\.isConfirmed)
        let overflow = confirmed.count - Self.maximumConfirmedSegmentCount
        guard overflow > 0 else { return false }

        let removedIds: Set<UUID> = switch edge {
        case .earliest:
            Set(confirmed.suffix(overflow).map(\.id))
        case .latest:
            Set(confirmed.prefix(overflow).map(\.id))
        }
        segments.removeAll { removedIds.contains($0.id) }
        return true
    }

    private func insertInTimeline(_ segment: TranscriptSegment) {
        if let existing = segments.firstIndex(where: { $0.id == segment.id }) {
            segments[existing] = segment
            return
        }
        let insertionIndex = segments.firstIndex(where: { Self.precedes(segment, $0) }) ?? segments.endIndex
        segments.insert(segment, at: insertionIndex)
    }

    private static func precedes(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.startTime == rhs.startTime {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.startTime < rhs.startTime
    }

    private func latestPreviews(in source: [TranscriptSegment]) -> [TranscriptSegment] {
        var previews: [String: TranscriptSegment] = [:]
        for segment in source where !segment.isConfirmed {
            previews[segment.speakerLabel ?? ""] = segment
        }
        return Array(previews.values)
    }

    private func clearUnconfirmedSegmentsImmediately(forSource sourceLabel: String?) {
        projectionRevision &+= 1
        let key = sourceLabel ?? ""
        unconfirmedThrottleTasks[key]?.cancel()
        unconfirmedThrottleTasks[key] = nil
        pendingUnconfirmed[key] = nil
        segments.removeAll { !$0.isConfirmed && $0.speakerLabel == sourceLabel }
        lastUnconfirmedUpdate[key] = .now
    }

    private func clearAllUnconfirmedSegmentsImmediately() {
        projectionRevision &+= 1
        unconfirmedThrottleTasks.values.forEach { $0.cancel() }
        unconfirmedThrottleTasks.removeAll()
        pendingUnconfirmed.removeAll()
        lastUnconfirmedUpdate.removeAll()
        segments.removeAll { !$0.isConfirmed }
    }

    private func scheduleUnconfirmedMutation(_ mutation: UnconfirmedMutation, forSource sourceLabel: String? = nil) {
        let key = sourceLabel ?? ""
        let now = ContinuousClock.now
        pendingUnconfirmed[key] = mutation

        let lastUpdate = lastUnconfirmedUpdate[key] ?? now - throttleInterval
        guard now - lastUpdate >= throttleInterval else {
            if unconfirmedThrottleTasks[key] == nil {
                unconfirmedThrottleTasks[key] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let pending = self.pendingUnconfirmed[key] else { return }
                    self.applyUnconfirmedMutation(pending, forSource: sourceLabel)
                    self.unconfirmedThrottleTasks[key] = nil
                }
            }
            return
        }

        applyUnconfirmedMutation(mutation, forSource: sourceLabel)
    }

    private func applyUnconfirmedMutation(_ mutation: UnconfirmedMutation, forSource sourceLabel: String? = nil) {
        projectionRevision &+= 1
        let existingIndex = segments.lastIndex(where: { !$0.isConfirmed && $0.speakerLabel == sourceLabel })

        switch mutation {
        case .clear:
            if let index = existingIndex {
                segments.remove(at: index)
            }
        case let .upsert(segment):
            if let index = existingIndex {
                segments[index] = segment
            } else {
                insertInTimeline(segment)
            }
        }

        let key = sourceLabel ?? ""
        lastUnconfirmedUpdate[key] = .now
        pendingUnconfirmed[key] = nil
    }

    private func mergedUnconfirmedSegment(_ segment: TranscriptSegment, forSource sourceLabel: String?) -> TranscriptSegment {
        let existingSegment = existingUnconfirmedSegment(forSource: sourceLabel)
        return TranscriptSegment(
            id: existingSegment?.id ?? segment.id,
            sessionId: segment.sessionId ?? existingSegment?.sessionId,
            startTime: segment.startTime,
            endTime: segment.endTime,
            text: segment.text,
            translatedText: segment.translatedText ?? existingSegment?.translatedText,
            isConfirmed: false,
            speakerLabel: segment.speakerLabel
        )
    }

    private func existingUnconfirmedSegment(forSource sourceLabel: String?) -> TranscriptSegment? {
        let key = sourceLabel ?? ""
        if let pendingMutation = pendingUnconfirmed[key] {
            switch pendingMutation {
            case .clear:
                return nil
            case let .upsert(segment):
                return segment
            }
        }

        return segments.last(where: { !$0.isConfirmed && $0.speakerLabel == sourceLabel })
    }
}

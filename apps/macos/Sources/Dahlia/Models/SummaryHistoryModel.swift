import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation

@MainActor @Observable
final class SummaryHistoryModel {
    private(set) var versions: [SummaryVersion] = []
    private(set) var nextCursor: String?
    private(set) var currentVersion: Int?
    private var loadedDocument: SummaryDocument?
    private var loadedVersion: Int?
    var document: SummaryDocument? { loadedVersion == selectedVersion ? loadedDocument : nil }
    private var loadGeneration = 0
    private var pageError: String?
    private var selectionError: String?
    private var promotionError: String?
    var error: String? { promotionError ?? pageError ?? selectionError }
    private(set) var isLoading = false
    private(set) var isPromoting = false
    var selectedVersion: Int?
    private let service = SummaryHistoryService()

    func load(meetingID: UUID, dbQueue: DatabaseQueue, more: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        pageError = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let page = try await service.page(meetingID: meetingID, dbQueue: dbQueue, before: more ? nextCursor : nil)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            versions = more ? versions + page.items : page.items
            nextCursor = page.nextCursor
            if !more { currentVersion = page.currentVersion ?? page.items.first?.version }
        } catch is CancellationError {
        } catch {
            // The first page loads unasked; its failure (an offline Server Account) must not sit above a readable summary.
            if more, !Task.isCancelled, generation == loadGeneration { self.pageError = error.localizedDescription }
        }
    }

    func select(meetingID: UUID, dbQueue: DatabaseQueue) async {
        loadedDocument = nil
        loadedVersion = nil
        selectionError = nil
        promotionError = nil
        guard let version = selectedVersion else { return }
        do {
            let loaded = try await service.document(meetingID: meetingID, version: version, dbQueue: dbQueue)
            try Task.checkCancellation()
            guard selectedVersion == version else { return }
            loadedDocument = loaded
            loadedVersion = version
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled, selectedVersion == version { self.selectionError = error.localizedDescription }
        }
    }

    func promote(meetingID: UUID, dbQueue: DatabaseQueue) async -> SummaryDocument? {
        guard !isPromoting, let version = selectedVersion, let document else { return nil }
        isPromoting = true
        promotionError = nil
        defer { isPromoting = false }
        do {
            try await service.promote(meetingID: meetingID, version: version, dbQueue: dbQueue)
            selectedVersion = nil
            currentVersion = version
            return document
        } catch {
            promotionError = error.localizedDescription
            return nil
        }
    }
}

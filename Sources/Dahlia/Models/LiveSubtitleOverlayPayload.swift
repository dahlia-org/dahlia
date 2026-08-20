import Foundation

struct LiveSubtitleOverlayPayload: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let primaryText: String
        let secondaryText: String?
        let isConfirmed: Bool
        fileprivate let sourceLabel: String?
    }

    final class EntryCollection: RandomAccessCollection {
        typealias Index = Int

        private var storage: [Entry]

        init(_ entries: [Entry] = []) {
            storage = entries
        }

        var startIndex: Int { storage.startIndex }
        var endIndex: Int { storage.endIndex }

        subscript(position: Int) -> Entry {
            storage[position]
        }

        func index(after index: Int) -> Int {
            storage.index(after: index)
        }

        func index(before index: Int) -> Int {
            storage.index(before: index)
        }

        fileprivate func replaceAll(with entries: [Entry]) {
            storage = entries
        }

        fileprivate func replace(_ entry: Entry, at index: Int) {
            storage[index] = entry
        }

        fileprivate func append(_ entry: Entry) {
            storage.append(entry)
        }

        fileprivate func insert(_ entry: Entry, at index: Int) {
            storage.insert(entry, at: index)
        }

        @discardableResult
        fileprivate func remove(at index: Int) -> Entry {
            storage.remove(at: index)
        }
    }

    let entries: EntryCollection
    let visibleEntryCount: Int
    private let revision: UInt64

    fileprivate init(entries: [Entry], visibleEntryCount: Int, revision: UInt64) {
        self.init(entries: EntryCollection(entries), visibleEntryCount: visibleEntryCount, revision: revision)
    }

    fileprivate init(entries: EntryCollection, visibleEntryCount: Int, revision: UInt64) {
        self.entries = entries
        self.visibleEntryCount = visibleEntryCount
        self.revision = revision
    }

    struct Configuration: Equatable {
        let sourceMode: LiveSubtitleSourceMode
        let showsTranslation: Bool

        init(
            sourceMode: LiveSubtitleSourceMode,
            transcriptionLocaleIdentifier: String,
            translationEnabled: Bool,
            targetLanguageIdentifier: String
        ) {
            self.sourceMode = sourceMode
            showsTranslation = translationEnabled && TranscriptTranslationLanguage.shouldTranslate(
                transcriptionLocaleIdentifier: transcriptionLocaleIdentifier,
                targetLanguageIdentifier: targetLanguageIdentifier
            )
        }
    }

    var visibleEntries: [Entry] {
        Array(entries.suffix(visibleEntryCount))
    }

    static func history(
        from segments: [TranscriptSegment],
        sourceMode: LiveSubtitleSourceMode = .defaultMode,
        transcriptionLocaleIdentifier: String,
        translationEnabled: Bool,
        targetLanguageIdentifier: String,
        visibleEntryCount: Int
    ) -> Self? {
        let configuration = Configuration(
            sourceMode: sourceMode,
            transcriptionLocaleIdentifier: transcriptionLocaleIdentifier,
            translationEnabled: translationEnabled,
            targetLanguageIdentifier: targetLanguageIdentifier
        )

        let entries = segments.compactMap { segment in
            entry(for: segment, configuration: configuration)
        }

        guard !entries.isEmpty else { return nil }
        return Self(entries: entries, visibleEntryCount: max(1, visibleEntryCount), revision: 0)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.revision == rhs.revision,
              lhs.visibleEntryCount == rhs.visibleEntryCount else { return false }
        return lhs.revision != 0 || lhs.entries.elementsEqual(rhs.entries)
    }

    fileprivate static func entry(for segment: TranscriptSegment, configuration: Configuration) -> Entry? {
        guard configuration.sourceMode.includesSpeakerLabel(segment.speakerLabel),
              let primaryText = segment.displayText.nilIfBlank else { return nil }

        return Entry(
            id: segment.id,
            primaryText: primaryText,
            secondaryText: configuration.showsTranslation ? segment.displayTranslatedText : nil,
            isConfirmed: segment.isConfirmed,
            sourceLabel: segment.speakerLabel
        )
    }
}

@MainActor
final class LiveSubtitleOverlayPayloadProjector {
    private var configuration: LiveSubtitleOverlayPayload.Configuration?
    private let entries = LiveSubtitleOverlayPayload.EntryCollection()
    private var entryIndices: [UUID: Int] = [:]
    private var confirmedEntryCount = 0
    private var revision: UInt64 = 0
    private var pendingChanges: [LiveCaptionStore.OverlayChange] = []
    private var needsReload = false

    func apply(_ change: LiveCaptionStore.OverlayChange) {
        if case .reload = change {
            needsReload = true
            pendingChanges.removeAll()
            return
        }
        guard !needsReload else { return }
        pendingChanges.append(change)
    }

    private func applyPendingChange(
        _ change: LiveCaptionStore.OverlayChange,
        configuration: LiveSubtitleOverlayPayload.Configuration
    ) {
        switch change {
        case .reload:
            break
        case let .preview(segment):
            replacePreview(with: segment, configuration: configuration)
        case let .finalized(segment):
            replaceFinalized(with: segment, configuration: configuration)
        case let .clearPreview(sourceLabel):
            guard configuration.sourceMode.includesSpeakerLabel(sourceLabel) else { return }
            guard let index = previewIndex(forSource: sourceLabel) else { return }
            removeEntry(at: index)
            revision &+= 1
        case let .update(segment):
            update(segment, configuration: configuration)
        }
    }

    func payload(
        from segments: [TranscriptSegment],
        configuration: LiveSubtitleOverlayPayload.Configuration,
        visibleEntryCount: Int
    ) -> LiveSubtitleOverlayPayload? {
        if self.configuration != configuration || needsReload {
            rebuild(from: segments, configuration: configuration)
        } else {
            for change in pendingChanges {
                applyPendingChange(change, configuration: configuration)
            }
            pendingChanges.removeAll()
        }
        guard !entries.isEmpty else { return nil }
        return LiveSubtitleOverlayPayload(
            entries: entries,
            visibleEntryCount: max(1, visibleEntryCount),
            revision: revision
        )
    }

    private func rebuild(
        from segments: [TranscriptSegment],
        configuration: LiveSubtitleOverlayPayload.Configuration
    ) {
        let rebuiltEntries = segments.compactMap {
            LiveSubtitleOverlayPayload.entry(for: $0, configuration: configuration)
        }
        entries.replaceAll(with: rebuiltEntries)
        entryIndices = Dictionary(uniqueKeysWithValues: rebuiltEntries.enumerated().map { ($1.id, $0) })
        confirmedEntryCount = rebuiltEntries.prefix(while: \.isConfirmed).count
        self.configuration = configuration
        needsReload = false
        pendingChanges.removeAll()
        revision &+= 1
    }

    private func replacePreview(
        with segment: TranscriptSegment,
        configuration: LiveSubtitleOverlayPayload.Configuration
    ) {
        guard configuration.sourceMode.includesSpeakerLabel(segment.speakerLabel) else { return }
        let existingIndex = previewIndex(forSource: segment.speakerLabel)
        let newEntry = LiveSubtitleOverlayPayload.entry(for: segment, configuration: configuration)
        guard existingIndex != nil || newEntry != nil else { return }

        if let existingIndex {
            removeEntry(at: existingIndex)
        }
        if let newEntry {
            entryIndices[newEntry.id] = entries.endIndex
            entries.append(newEntry)
        }
        revision &+= 1
    }

    private func replaceFinalized(
        with segment: TranscriptSegment,
        configuration: LiveSubtitleOverlayPayload.Configuration
    ) {
        guard configuration.sourceMode.includesSpeakerLabel(segment.speakerLabel) else { return }
        if let previewIndex = previewIndex(forSource: segment.speakerLabel) {
            removeEntry(at: previewIndex)
        }
        let existingIndex = entryIndices[segment.id]
        guard let newEntry = LiveSubtitleOverlayPayload.entry(for: segment, configuration: configuration) else {
            if let existingIndex {
                removeEntry(at: existingIndex)
            }
            revision &+= 1
            return
        }
        if let existingIndex {
            entries.replace(newEntry, at: existingIndex)
        } else {
            insertConfirmed(newEntry)
        }
        revision &+= 1
    }

    private func update(
        _ segment: TranscriptSegment,
        configuration: LiveSubtitleOverlayPayload.Configuration
    ) {
        guard configuration.sourceMode.includesSpeakerLabel(segment.speakerLabel) else { return }
        guard let index = entryIndices[segment.id] else { return }
        guard let updatedEntry = LiveSubtitleOverlayPayload.entry(for: segment, configuration: configuration) else {
            removeEntry(at: index)
            revision &+= 1
            return
        }
        guard entries[index] != updatedEntry else { return }
        entries.replace(updatedEntry, at: index)
        revision &+= 1
    }

    private func previewIndex(forSource sourceLabel: String?) -> Int? {
        var index = entries.endIndex
        while index > confirmedEntryCount {
            index = entries.index(before: index)
            if entries[index].sourceLabel == sourceLabel {
                return index
            }
        }
        return nil
    }

    private func insertConfirmed(_ entry: LiveSubtitleOverlayPayload.Entry) {
        entries.insert(entry, at: confirmedEntryCount)
        refreshIndices(from: confirmedEntryCount)
        confirmedEntryCount += 1
    }

    private func removeEntry(at index: Int) {
        let removedEntry = entries.remove(at: index)
        entryIndices.removeValue(forKey: removedEntry.id)
        if removedEntry.isConfirmed {
            confirmedEntryCount -= 1
        }
        refreshIndices(from: index)
    }

    private func refreshIndices(from startIndex: Int) {
        for index in startIndex ..< entries.endIndex {
            entryIndices[entries[index].id] = index
        }
    }
}

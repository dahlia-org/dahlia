import Foundation

struct LiveSubtitleOverlayPayload: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let primaryText: String
        let secondaryText: String?
    }

    let entries: [Entry]
    let visibleEntryCount: Int

    var visibleEntries: ArraySlice<Entry> {
        entries.suffix(visibleEntryCount)
    }

    static func history(
        from segments: [TranscriptSegment],
        sourceMode: LiveSubtitleSourceMode = .defaultMode,
        transcriptionLocaleIdentifier: String,
        translationEnabled: Bool,
        targetLanguageIdentifier: String,
        visibleEntryCount: Int
    ) -> Self? {
        let showsTranslation = translationEnabled && TranscriptTranslationLanguage.shouldTranslate(
            transcriptionLocaleIdentifier: transcriptionLocaleIdentifier,
            targetLanguageIdentifier: targetLanguageIdentifier
        )

        let entries = segments.compactMap { segment in
            entry(
                for: segment,
                sourceMode: sourceMode,
                showsTranslation: showsTranslation
            )
        }

        guard !entries.isEmpty else { return nil }
        return Self(entries: entries, visibleEntryCount: max(1, visibleEntryCount))
    }

    private static func entry(
        for segment: TranscriptSegment,
        sourceMode: LiveSubtitleSourceMode,
        showsTranslation: Bool
    ) -> Entry? {
        guard sourceMode.includesSpeakerLabel(segment.speakerLabel),
              let primaryText = segment.displayText.nilIfBlank else { return nil }

        return Entry(
            id: segment.id,
            primaryText: primaryText,
            secondaryText: showsTranslation ? segment.displayTranslatedText : nil
        )
    }
}

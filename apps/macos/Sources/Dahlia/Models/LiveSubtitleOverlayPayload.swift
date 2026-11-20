import Foundation

/// The latest live captions the overlay shows. Only the newest `count` entries exist here; the full session history
/// stays in `LiveCaptionStore` and the transcript tab.
struct LiveSubtitleOverlayPayload: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let primaryText: String
        let secondaryText: String?
        let isConfirmed: Bool
    }

    let entries: [Entry]

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

    /// Scans back from the newest segment and stops after `count` shown entries.
    static func latest(
        from segments: [TranscriptSegment],
        configuration: Configuration,
        count: Int
    ) -> Self? {
        var entries: [Entry] = []
        for segment in segments.reversed() where entries.count < max(1, count) {
            guard configuration.sourceMode.includesAudioSource(segment.audioSource),
                  let primaryText = segment.displayText.nilIfBlank else { continue }
            entries.append(Entry(
                id: segment.id,
                primaryText: primaryText,
                secondaryText: configuration.showsTranslation ? segment.displayTranslatedText : nil,
                isConfirmed: segment.isConfirmed
            ))
        }
        return entries.isEmpty ? nil : Self(entries: entries.reversed())
    }

    static func latest(
        from segments: [TranscriptSegment],
        sourceMode: LiveSubtitleSourceMode = .defaultMode,
        transcriptionLocaleIdentifier: String,
        translationEnabled: Bool,
        targetLanguageIdentifier: String,
        visibleEntryCount: Int
    ) -> Self? {
        latest(
            from: segments,
            configuration: Configuration(
                sourceMode: sourceMode,
                transcriptionLocaleIdentifier: transcriptionLocaleIdentifier,
                translationEnabled: translationEnabled,
                targetLanguageIdentifier: targetLanguageIdentifier
            ),
            count: visibleEntryCount
        )
    }
}

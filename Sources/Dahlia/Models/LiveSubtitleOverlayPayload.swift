import Foundation

struct LiveSubtitleOverlayPayload: Equatable {
    struct Entry: Equatable {
        let primaryText: String
        let secondaryText: String?
    }

    let entries: [Entry]

    static func latest(
        from segments: [TranscriptSegment],
        sourceMode: LiveSubtitleSourceMode = .includeMicrophone,
        transcriptionLocaleIdentifier: String,
        translationEnabled: Bool,
        targetLanguageIdentifier: String,
        maxEntries: Int
    ) -> Self? {
        let clampedMaxEntries = max(1, maxEntries)
        let showsTranslation = translationEnabled && TranscriptTranslationLanguage.shouldTranslate(
            transcriptionLocaleIdentifier: transcriptionLocaleIdentifier,
            targetLanguageIdentifier: targetLanguageIdentifier
        )

        var latestConfirmedEntriesReversed: [Entry] = []
        var entriesAroundUnconfirmedReversed: [Entry] = []
        var foundUnconfirmed = false

        for segment in segments.reversed() {
            if !foundUnconfirmed,
               segment.isConfirmed,
               latestConfirmedEntriesReversed.count >= clampedMaxEntries {
                continue
            }

            guard let entry = entry(
                for: segment,
                sourceMode: sourceMode,
                showsTranslation: showsTranslation
            ) else { continue }

            if foundUnconfirmed {
                entriesAroundUnconfirmedReversed.append(entry)
            } else if segment.isConfirmed {
                if latestConfirmedEntriesReversed.count < clampedMaxEntries {
                    latestConfirmedEntriesReversed.append(entry)
                }
            } else {
                foundUnconfirmed = true
                entriesAroundUnconfirmedReversed.append(entry)
            }

            if foundUnconfirmed, entriesAroundUnconfirmedReversed.count >= clampedMaxEntries {
                break
            }
        }

        let reversedEntries = foundUnconfirmed ? entriesAroundUnconfirmedReversed : latestConfirmedEntriesReversed
        guard !reversedEntries.isEmpty else { return nil }
        return Self(entries: Array(reversedEntries.reversed()))
    }

    private static func entry(
        for segment: TranscriptSegment,
        sourceMode: LiveSubtitleSourceMode,
        showsTranslation: Bool
    ) -> Entry? {
        guard sourceMode.includesSpeakerLabel(segment.speakerLabel),
              let primaryText = segment.displayText.nilIfBlank else { return nil }

        return Entry(
            primaryText: primaryText,
            secondaryText: showsTranslation ? segment.displayTranslatedText : nil
        )
    }
}

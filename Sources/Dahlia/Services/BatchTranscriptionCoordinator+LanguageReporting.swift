extension BatchTranscriptionCoordinator {
    func reportLanguageFallbacks(
        _ fallbacks: [BatchLanguageFallback],
        allowedLanguageIdentifiers: Set<String>?
    ) async {
        guard !fallbacks.isEmpty else { return }
        await languageFallbackReporter(fallbacks, allowedLanguageIdentifiers)
    }

    static func languageFallbackReportContext(
        _ fallbacks: [BatchLanguageFallback],
        allowedLanguageIdentifiers: Set<String>? = nil
    ) -> [String: String] {
        let reasonCounts = Dictionary(grouping: fallbacks, by: \.reason).mapValues(\.count)
        return [
            "source": "batchLanguageDetectionFallback",
            "candidateScope": allowedLanguageIdentifiers == nil ? "all" : "selected",
            "candidateLanguageCount": allowedLanguageIdentifiers.map { String($0.count) } ?? "unrestricted",
            "fallbackCount": String(fallbacks.count),
            "detectionFailedCount": String(reasonCounts[.detectionFailed, default: 0]),
            "lowConfidenceCount": String(reasonCounts[.lowConfidence, default: 0]),
            "unsupportedLanguageCount": String(reasonCounts[.unsupportedLanguage, default: 0]),
        ]
    }
}

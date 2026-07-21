extension BatchTranscriptionCoordinator {
    func reportLanguageFallbacks(
        _ fallbacks: [BatchLanguageFallback],
        candidates: BatchLanguageDetectionCandidateSnapshot?
    ) async {
        guard !fallbacks.isEmpty, let candidates else { return }
        await languageFallbackReporter(fallbacks, candidates)
    }

    static func languageFallbackReportContext(
        _ fallbacks: [BatchLanguageFallback],
        candidates: BatchLanguageDetectionCandidateSnapshot
    ) -> [String: String] {
        [
            "source": "batchLanguageDetectionFallback",
            "candidateScope": candidates.scope.rawValue,
            "candidateLanguageCount": String(candidates.languageIdentifiers.count),
            "fallbackCount": String(fallbacks.count),
            "inferenceFailedCount": String(fallbacks.count),
        ]
    }
}

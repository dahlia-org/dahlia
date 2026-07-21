import Foundation
import os
import Translation

struct TranscriptBatchTranslationInput: Sendable {
    let sourceText: String
    let clientIdentifier: String
}

struct TranscriptBatchTranslationOutput: Sendable {
    let targetText: String
    let clientIdentifier: String?
}

protocol TranscriptBatchTranslationSession: Sendable {
    func translations(
        from requests: [TranscriptBatchTranslationInput]
    ) async throws -> [TranscriptBatchTranslationOutput]
}

/// The owning TranscriptTranslationService actor invokes this session serially.
private struct AppleTranscriptBatchTranslationSession: TranscriptBatchTranslationSession, @unchecked Sendable {
    let session: TranslationSession

    func translations(
        from requests: [TranscriptBatchTranslationInput]
    ) async throws -> [TranscriptBatchTranslationOutput] {
        let responses = try await session.translations(
            from: requests.map {
                TranslationSession.Request(
                    sourceText: $0.sourceText,
                    clientIdentifier: $0.clientIdentifier
                )
            }
        )
        return responses.map {
            TranscriptBatchTranslationOutput(
                targetText: $0.targetText,
                clientIdentifier: $0.clientIdentifier
            )
        }
    }
}

actor TranscriptTranslationService {
    typealias BatchSessionFactory = @Sendable (
        Locale.Language,
        Locale.Language
    ) async -> any TranscriptBatchTranslationSession
    typealias LanguagePairSupportProvider = @Sendable (
        Locale.Language,
        Locale.Language
    ) async -> Bool

    struct BatchRequest: Sendable {
        let id: UUID
        let text: String
        let sourceLocaleIdentifier: String
    }

    private struct LanguagePair: Hashable {
        let sourceLanguageIdentifier: String
        let targetLanguageIdentifier: String
    }

    private let logger = Logger(subsystem: "com.dahlia", category: "TranscriptTranslation")
    private let batchSessionFactory: BatchSessionFactory
    private let languagePairSupportProvider: LanguagePairSupportProvider?

    private var availabilityStatuses: [LanguagePair: LanguageAvailability.Status] = [:]

    init(
        batchSessionFactory: @escaping BatchSessionFactory = { source, target in
            AppleTranscriptBatchTranslationSession(
                session: TranslationSession(installedSource: source, target: target)
            )
        },
        languagePairSupportProvider: LanguagePairSupportProvider? = nil
    ) {
        self.batchSessionFactory = batchSessionFactory
        self.languagePairSupportProvider = languagePairSupportProvider
    }

    func translate(
        _ text: String,
        from sourceLocaleIdentifier: String,
        to targetLanguageIdentifier: String
    ) async -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        let sourceLanguage = Locale(identifier: sourceLocaleIdentifier).language
        let targetLanguage = Locale.Language(
            identifier: TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: targetLanguageIdentifier)
        )
        guard await isSupportedLanguagePair(source: sourceLanguage, target: targetLanguage) else {
            return nil
        }

        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)

        do {
            let response = try await session.translate(trimmedText)
            return response.targetText.nilIfBlank
        } catch {
            logger.error("Translation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Uses one TranslationSession per language pair and submits multiple transcript
    /// segments together, avoiding model/session setup between every recognized utterance.
    func translateBatch(
        _ requests: [BatchRequest],
        to targetLanguageIdentifier: String
    ) async throws -> [UUID: String] {
        try Task.checkCancellation()
        let requests = requests.compactMap { request -> BatchRequest? in
            let trimmedText = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return nil }
            return BatchRequest(
                id: request.id,
                text: trimmedText,
                sourceLocaleIdentifier: request.sourceLocaleIdentifier
            )
        }
        let grouped = Dictionary(grouping: requests) {
            Locale(identifier: $0.sourceLocaleIdentifier).language.maximalIdentifier
        }
        let targetLanguage = Locale.Language(
            identifier: TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: targetLanguageIdentifier)
        )
        var translatedById: [UUID: String] = [:]

        for (sourceLanguageIdentifier, pairRequests) in grouped {
            try Task.checkCancellation()
            let sourceLanguage = Locale.Language(identifier: sourceLanguageIdentifier)
            guard await isSupportedLanguagePair(source: sourceLanguage, target: targetLanguage) else {
                continue
            }
            let session = await batchSessionFactory(sourceLanguage, targetLanguage)
            // Bound each framework request while still amortizing session and model setup.
            for startIndex in stride(from: 0, to: pairRequests.count, by: 100) {
                let chunk = pairRequests[startIndex ..< min(startIndex + 100, pairRequests.count)]
                do {
                    let responses = try await session.translations(from: chunk.map {
                        TranscriptBatchTranslationInput(
                            sourceText: $0.text,
                            clientIdentifier: $0.id.uuidString
                        )
                    })
                    for response in responses {
                        guard let clientIdentifier = response.clientIdentifier,
                              let id = UUID(uuidString: clientIdentifier),
                              let translatedText = response.targetText.nilIfBlank else { continue }
                        translatedById[id] = translatedText
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.error("Batch translation failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return translatedById
    }

    private func isSupportedLanguagePair(source: Locale.Language, target: Locale.Language) async -> Bool {
        if let languagePairSupportProvider {
            return await languagePairSupportProvider(source, target)
        }
        let pair = LanguagePair(
            sourceLanguageIdentifier: source.maximalIdentifier,
            targetLanguageIdentifier: target.maximalIdentifier
        )

        if let availabilityStatus = availabilityStatuses[pair] {
            return availabilityStatus != .unsupported
        }

        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        availabilityStatuses[pair] = status
        if status == .unsupported {
            logger.warning(
                "Translation is unsupported for \(pair.sourceLanguageIdentifier, privacy: .public) -> \(pair.targetLanguageIdentifier, privacy: .public)"
            )
        }
        return status != .unsupported
    }
}

import CoreML
import Foundation
import WhisperKit

/// Keeps WhisperKit's language detection inference unchanged while limiting which
/// language token may win sampling. The returned probability is still normalized
/// across every Whisper language so the existing confidence threshold remains
/// conservative when the candidate set is small.
final class CandidateRestrictedTextDecoder: TextDecoding, WhisperMLModel {
    private let base = TextDecoder()

    var allowedLanguageIdentifiers: Set<String>?

    var model: MLModel? {
        get { base.model }
        set { base.model = newValue }
    }

    var tokenizer: WhisperTokenizer? {
        get { base.tokenizer }
        set { base.tokenizer = newValue }
    }

    var isModelMultilingual: Bool {
        get { base.isModelMultilingual }
        set { base.isModelMultilingual = newValue }
    }

    var supportsWordTimestamps: Bool { base.supportsWordTimestamps }
    var logitsSize: Int? { base.logitsSize }

    var logitsFilters: [any LogitsFiltering]? {
        get { base.logitsFilters }
        set { base.logitsFilters = newValue }
    }

    var kvCacheEmbedDim: Int? { base.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { base.kvCacheMaxSequenceLength }
    var windowSize: Int? { base.windowSize }
    var embedSize: Int? { base.embedSize }

    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> TextDecoderOutputType? {
        try await base.predictLogits(inputs)
    }

    func decodeText(
        from encoderOutput: any AudioEncoderOutputType,
        using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: TokenSampling,
        options decoderOptions: DecodingOptions,
        callback: TranscriptionCallback?
    ) async throws -> DecodingResult {
        try await base.decodeText(
            from: encoderOutput,
            using: decoderInputs,
            sampler: tokenSampler,
            options: decoderOptions,
            callback: callback
        )
    }

    func detectLanguage(
        from encoderOutput: any AudioEncoderOutputType,
        using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: TokenSampling,
        options: DecodingOptions,
        temperature: FloatType
    ) async throws -> DecodingResult {
        guard let allowedLanguageIdentifiers else {
            return try await base.detectLanguage(
                from: encoderOutput,
                using: decoderInputs,
                sampler: tokenSampler,
                options: options,
                temperature: temperature
            )
        }
        guard let tokenizer else {
            throw WhisperError.tokenizerUnavailable()
        }

        let allLanguageTokenIDs = Set(tokenizer.allLanguageTokens)
        let allowedLanguageTokenIDs = Set(
            allowedLanguageIdentifiers.compactMap { identifier in
                WhisperLanguageIdentifier.canonicalIdentifier(from: identifier)
                    .flatMap { tokenizer.convertTokenToId("<|\($0)|>") }
            }
        ).intersection(allLanguageTokenIDs)
        guard !allowedLanguageTokenIDs.isEmpty else {
            throw WhisperError.decodingFailed("No configured language is supported by the Whisper tokenizer")
        }

        let restrictedSampler = CandidateRestrictedTokenSampler(
            allowedLanguageTokenIDs: allowedLanguageTokenIDs,
            allLanguageTokenIDs: allLanguageTokenIDs,
            endToken: tokenizer.specialTokens.endToken
        )
        return try await base.detectLanguage(
            from: encoderOutput,
            using: decoderInputs,
            sampler: restrictedSampler,
            options: options,
            temperature: temperature
        )
    }
}

struct CandidateRestrictedTokenSampler: TokenSampling {
    let allowedLanguageTokenIDs: Set<Int>
    let allLanguageTokenIDs: Set<Int>
    let endToken: Int

    func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        let validAllTokenIDs = allLanguageTokenIDs.filter { (0 ..< logits.count).contains($0) }
        let validAllowedTokenIDs = allowedLanguageTokenIDs.intersection(validAllTokenIDs)
        guard let chosenToken = validAllowedTokenIDs.max(by: { left, right in
            let leftLogit = logits[left].floatValue
            let rightLogit = logits[right].floatValue
            return leftLogit == rightLogit ? left > right : leftLogit < rightLogit
        }) else {
            return SamplingResult(tokens: tokens, logProbs: logProbs, completed: true)
        }

        let languageLogits = validAllTokenIDs.map { logits[$0].floatValue }
        let maximumLogit = languageLogits.max() ?? -.infinity
        let denominator = languageLogits.reduce(Float.zero) { result, logit in
            result + exp(logit - maximumLogit)
        }
        let chosenLogProbability: Float = if maximumLogit.isFinite, denominator > 0 {
            logits[chosenToken].floatValue - maximumLogit - log(denominator)
        } else {
            -.infinity
        }

        return SamplingResult(
            tokens: tokens + [chosenToken],
            logProbs: logProbs + [chosenLogProbability],
            completed: chosenToken == endToken
        )
    }

    func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        guard tokens.last != endToken else {
            return SamplingResult(tokens: tokens, logProbs: logProbs, completed: true)
        }
        return SamplingResult(
            tokens: tokens + [endToken],
            logProbs: logProbs + [0],
            completed: true
        )
    }
}

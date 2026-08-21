import Accelerate
import CryptoKit
import DahliaRuntimeSupport
import Foundation
import Hub
import MLX
import MLXEmbedders
import MLXLMCommon
import OSLog
import Tokenizers

enum EmbeddingGemmaDescriptor {
    static let repository = "mlx-community/embeddinggemma-300m-4bit"
    static let revision = "5d9ef074df3957afc5c77127f208fddbc3c54187"
    static let dimensions = 256
    static let maximumTokens = 2048
    static let queryPrompt = "task: search result | query: "
    static let documentPrompt = "title: %@ | text: %@"
    static let modelIdentifier = "\(repository)@\(revision)"
    static let configurationHash = sha256(
        "\(modelIdentifier)|\(dimensions)|\(maximumTokens)|\(queryPrompt)|\(documentPrompt)|meeting-v3|project-v1"
    )
    static let fileChecksums = [
        "added_tokens.json": "50b2f405ba56a26d4913fd772089992252d7f942123cc0a034d96424221ba946",
        "config.json": "8f7e856558357fea02487ff368eac6dd899fcc557290e34efa70ffd4d6ea78e8",
        "model.safetensors": "f2366c4c0dfdac15b30548ee44c9e06d7e7c0eb0bd13d26279f953fe2c9b278a",
        "model.safetensors.index.json": "98a2ae36bcda747cb785d60ed521bd5a31c36406fc23117ad8435bc4cb32735b",
        "special_tokens_map.json": "2f7b0adf4fb469770bb1490e3e35df87b1dc578246c5e7e6fc76ecf33213a397",
        "tokenizer.json": "6852f8d561078cc0cebe70ca03c5bfdd0d60a45f9d2e0e1e4cc05b68e9ec329e",
        "tokenizer.model": "1299c11d7cf632ef3b4e11937501358ada021bbdf7c47638d13c0ee982f2e79c",
        "tokenizer_config.json": "9076840490613047bc9115963ee96b7702018b0d26ba644240bf856efda93118",
    ]

    static func limitedTokens(_ tokens: [Int]) -> [Int] {
        guard tokens.count > maximumTokens, let endToken = tokens.last else { return tokens }
        return Array(tokens.prefix(maximumTokens - 1)) + [endToken]
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum MLXRuntimeResources {
    static var hasMetalLibrary: Bool {
        hasMetalLibrary(
            bundleURL: Bundle.main.bundleURL,
            resourceURL: Bundle.main.resourceURL,
            executableURL: Bundle.main.executableURL
        )
    }

    static func hasMetalLibrary(bundleURL: URL, resourceURL: URL?, executableURL: URL?) -> Bool {
        let fileManager = FileManager.default
        let candidates = [
            executableURL?.deletingLastPathComponent().appending(path: "mlx.metallib"),
            bundleURL.appending(path: "mlx-swift_Cmlx.bundle/default.metallib"),
            resourceURL?.appending(path: "mlx-swift_Cmlx.bundle/default.metallib"),
            resourceURL?.appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
        ]
        return candidates.compactMap(\.self).contains { fileManager.fileExists(atPath: $0.path) }
    }
}

protocol TextEmbeddingProviding: Sendable {
    var isAvailable: Bool { get async }
    func queryEmbedding(_ query: String) async throws -> [Float]
    func documentEmbeddings(_ documents: [DocumentEmbeddingInput]) async throws -> [[Float]]
}

struct DocumentEmbeddingInput: Sendable {
    let title: String
    let text: String
}

struct EmbeddingTokenBatch: Equatable, Sendable {
    let sourceIndices: [Int]
    let paddedTokens: [[Int]]
    let attentionMask: [[Int]]
}

enum EmbeddingBatchPlanner {
    static let maximumDocuments = 4
    static let maximumPaddedTokens = 4096

    static func batches(for tokenSequences: [[Int]], paddingToken: Int = 0) -> [EmbeddingTokenBatch] {
        var result: [EmbeddingTokenBatch] = []
        var indices: [Int] = []
        var sequences: [[Int]] = []
        var maximumLength = 0

        func appendBatch() {
            guard !sequences.isEmpty else { return }
            result.append(EmbeddingTokenBatch(
                sourceIndices: indices,
                paddedTokens: sequences.map {
                    $0 + Array(repeating: paddingToken, count: maximumLength - $0.count)
                },
                attentionMask: sequences.map {
                    Array(repeating: 1, count: $0.count)
                        + Array(repeating: 0, count: maximumLength - $0.count)
                }
            ))
        }

        for (index, sequence) in tokenSequences.enumerated() {
            let candidateMaximum = max(maximumLength, sequence.count)
            let exceedsBudget = candidateMaximum * (sequences.count + 1) > maximumPaddedTokens
            if sequences.count == maximumDocuments || (!sequences.isEmpty && exceedsBudget) {
                appendBatch()
                indices.removeAll(keepingCapacity: true)
                sequences.removeAll(keepingCapacity: true)
                maximumLength = 0
            }
            indices.append(index)
            sequences.append(sequence)
            maximumLength = max(maximumLength, sequence.count)
        }
        appendBatch()
        return result
    }
}

enum EmbeddingVector {
    static func truncateAndNormalize(_ values: [Float]) throws -> [Float] {
        guard values.count >= EmbeddingGemmaDescriptor.dimensions else {
            throw EmbeddingGemmaError.invalidDimensions(values.count)
        }
        let truncated = Array(values.prefix(EmbeddingGemmaDescriptor.dimensions))
        let magnitude = sqrt(truncated.reduce(0) { $0 + $1 * $1 })
        guard magnitude.isFinite, magnitude > 0 else { throw EmbeddingGemmaError.invalidVector }
        return truncated.map { $0 / magnitude }
    }

    static func encode(_ values: [Float]) throws -> Data {
        guard values.count == EmbeddingGemmaDescriptor.dimensions else {
            throw EmbeddingGemmaError.invalidDimensions(values.count)
        }
        return values.withUnsafeBytes { Data($0) }
    }

    static func decode(_ data: Data) throws -> [Float] {
        guard data.count == EmbeddingGemmaDescriptor.dimensions * MemoryLayout<Float>.size else {
            throw EmbeddingGemmaError.invalidDataSize(data.count)
        }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) throws -> Float {
        guard lhs.count == EmbeddingGemmaDescriptor.dimensions,
              rhs.count == EmbeddingGemmaDescriptor.dimensions else {
            throw EmbeddingGemmaError.invalidDimensions(min(lhs.count, rhs.count))
        }
        var result: Float = 0
        vDSP_dotpr(
            lhs,
            1,
            rhs,
            1,
            &result,
            vDSP_Length(EmbeddingGemmaDescriptor.dimensions)
        )
        return result
    }
}

actor EmbeddingGemmaService: TextEmbeddingProviding {
    private static let logger = Logger(subsystem: "com.dahlia", category: "VectorEmbedding")

    private let installDirectory: URL
    private let validatesRuntimeResources: Bool
    private var container: EmbedderModelContainer?
    private var containerLoadTask: Task<EmbedderModelContainer, Error>?

    init(
        baseDirectory: URL = DahliaApplicationSupport.currentDirectoryURL,
        validatesRuntimeResources: Bool = true
    ) {
        installDirectory = baseDirectory
            .appending(path: "Models/EmbeddingGemma")
            .appending(path: EmbeddingGemmaDescriptor.revision)
        self.validatesRuntimeResources = validatesRuntimeResources
    }

    var isInstalled: Bool {
        EmbeddingGemmaDescriptor.fileChecksums.keys.allSatisfy {
            FileManager.default.fileExists(atPath: installDirectory.appending(path: $0).path)
        }
    }

    var isAvailable: Bool { isInstalled && (!validatesRuntimeResources || MLXRuntimeResources.hasMetalLibrary) }

    func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        if isInstalled, try verifiesChecksums(at: installDirectory) { return }
        let parent = installDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryRoot = parent.appending(path: ".download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let hub = HubApi(downloadBase: temporaryRoot)
        let downloaded = try await hub.snapshot(
            from: EmbeddingGemmaDescriptor.repository,
            revision: EmbeddingGemmaDescriptor.revision
        ) { value in
            progress(value.fractionCompleted)
        }
        guard try verifiesChecksums(at: downloaded) else { throw EmbeddingGemmaError.checksumMismatch }
        if FileManager.default.fileExists(atPath: installDirectory.path) {
            _ = try FileManager.default.replaceItemAt(installDirectory, withItemAt: downloaded)
        } else {
            try FileManager.default.moveItem(at: downloaded, to: installDirectory)
        }
        container = nil
        containerLoadTask = nil
    }

    func queryEmbedding(_ query: String) async throws -> [Float] {
        guard let embedding = try await embed([EmbeddingGemmaDescriptor.queryPrompt + query]).first else {
            throw EmbeddingGemmaError.emptyInput
        }
        return embedding
    }

    func documentEmbeddings(_ documents: [DocumentEmbeddingInput]) async throws -> [[Float]] {
        try await embed(documents.map {
            String(
                format: EmbeddingGemmaDescriptor.documentPrompt,
                $0.title.isEmpty ? "none" : $0.title,
                $0.text
            )
        })
    }

    private func embed(_ prompts: [String]) async throws -> [[Float]] {
        guard !prompts.isEmpty else { return [] }
        let model = try await loadedContainer()
        return try await model.perform { context in
            let clock = ContinuousClock()
            var tokenizeDurations: [Duration] = []
            let tokenSequences = try prompts.map { prompt in
                let startedAt = clock.now
                let tokens = EmbeddingGemmaDescriptor.limitedTokens(
                    context.tokenizer.encode(text: prompt, addSpecialTokens: true)
                )
                tokenizeDurations.append(startedAt.duration(to: clock.now))
                guard !tokens.isEmpty else { throw EmbeddingGemmaError.emptyInput }
                return tokens
            }
            let batches = EmbeddingBatchPlanner.batches(for: tokenSequences)
            var embeddings = Array(repeating: [Float](), count: prompts.count)

            for batch in batches {
                try Task.checkCancellation()
                let forwardStartedAt = clock.now
                let input = stacked(batch.paddedTokens.map { MLXArray($0) })
                let mask = stacked(batch.attentionMask.map { MLXArray($0) }).asType(.float32)
                guard let output = context.model(
                    input,
                    positionIds: nil,
                    tokenTypeIds: nil,
                    attentionMask: mask
                ).pooledOutput else { throw EmbeddingGemmaError.missingOutput }
                output.eval()
                let forwardDuration = forwardStartedAt.duration(to: clock.now)

                let normalizationStartedAt = clock.now
                let rawValues = output.asArray(Float.self)
                let outputDimensions = output.dim(1)
                for (row, sourceIndex) in batch.sourceIndices.enumerated() {
                    let start = row * outputDimensions
                    embeddings[sourceIndex] = try EmbeddingVector.truncateAndNormalize(
                        Array(rawValues[start ..< start + outputDimensions])
                    )
                }
                let normalizationDuration = normalizationStartedAt.duration(to: clock.now)
                let tokenizeDuration = batch.sourceIndices.reduce(Duration.zero) {
                    $0 + tokenizeDurations[$1]
                }
                let batchDuration = tokenizeDuration + forwardDuration + normalizationDuration
                let count = batch.sourceIndices.count
                Self.logger.debug(
                    "Embedding batch documents=\(count, privacy: .public) padded_tokens=\(input.size, privacy: .public) tokenize_ms=\(tokenizeDuration.milliseconds, privacy: .public) forward_eval_ms=\(forwardDuration.milliseconds, privacy: .public) normalize_ms=\(normalizationDuration.milliseconds, privacy: .public) batch_ms=\(batchDuration.milliseconds, privacy: .public) per_document_ms=\(batchDuration.milliseconds / Double(count), privacy: .public)"
                )
            }
            return embeddings
        }
    }

    private func loadedContainer() async throws -> EmbedderModelContainer {
        if let container { return container }
        if let containerLoadTask { return try await containerLoadTask.value }
        guard isInstalled, try verifiesChecksums(at: installDirectory) else {
            throw EmbeddingGemmaError.modelNotInstalled
        }
        guard !validatesRuntimeResources || MLXRuntimeResources.hasMetalLibrary else {
            throw EmbeddingGemmaError.metalLibraryMissing
        }
        let task = Task {
            try await EmbedderModelFactory.shared.loadContainer(
                from: installDirectory,
                using: TransformersTokenizerLoader()
            )
        }
        containerLoadTask = task
        do {
            let loaded = try await task.value
            container = loaded
            containerLoadTask = nil
            return loaded
        } catch {
            containerLoadTask = nil
            throw error
        }
    }

    private func verifiesChecksums(at directory: URL) throws -> Bool {
        for (filename, expected) in EmbeddingGemmaDescriptor.fileChecksums {
            let url = directory.appending(path: filename)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            let actual = try SHA256.hash(data: Data(contentsOf: url)).map {
                String(format: "%02x", $0)
            }.joined()
            guard actual == expected else { return false }
        }
        return true
    }
}

private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try await TransformersTokenizer(Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

enum EmbeddingGemmaError: Error {
    case checksumMismatch
    case emptyInput
    case invalidDataSize(Int)
    case invalidDimensions(Int)
    case invalidVector
    case missingOutput
    case metalLibraryMissing
    case modelNotInstalled
}

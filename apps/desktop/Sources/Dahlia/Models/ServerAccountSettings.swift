import Foundation

struct ServerAccountSettings: Codable, Equatable, Sendable {
    struct AnalysisLanguages: Codable, Equatable, Sendable {
        var scope: AppLanguageScope
        var identifiers: [String]
    }

    enum SummaryMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case local, remote
        var id: Self { self }
    }

    struct RemoteSummarySettings: Codable, Equatable, Sendable {
        var detail = "high"
        var model = "gemini-3-8-flash"
        var reasoningEffort = "medium"
        var transcriptionModel: String?
    }

    struct Summary: Codable, Equatable, Sendable {
        var mode: SummaryMode
        var remote: RemoteSummarySettings
        private(set) var legacyMethod: String?

        private enum CodingKeys: String, CodingKey { case mode, remote, method, detail, methodSettings, legacyMethod }
        private struct LegacyModelSettings: Decodable {
            var model: String
            var reasoningEffort: String
        }

        private struct LegacyMethodSettings: Decodable {
            var transcript: LegacyModelSettings?
            var audio: LegacyModelSettings?
        }

        init(mode: SummaryMode, remote: RemoteSummarySettings) {
            self.mode = mode
            self.remote = remote
            legacyMethod = nil
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let mode = try values.decodeIfPresent(SummaryMode.self, forKey: .mode) {
                try self.init(mode: mode, remote: values.decode(RemoteSummarySettings.self, forKey: .remote))
                legacyMethod = try values.decodeIfPresent(String.self, forKey: .legacyMethod)
                return
            }
            let method = try values.decode(String.self, forKey: .method)
            let detail = try values.decodeIfPresent(String.self, forKey: .detail) ?? "high"
            let legacy = try values.decodeIfPresent(LegacyMethodSettings.self, forKey: .methodSettings)
            let selected = method == "audio" ? legacy?.audio : legacy?.transcript
            let remote = RemoteSummarySettings(
                detail: detail,
                model: selected?.model ?? "gemini-3-8-flash",
                reasoningEffort: selected?.reasoningEffort ?? "medium",
                transcriptionModel: method == "cloudTranscription"
                    ? legacy?.audio?.model ?? "gemini-3-8-flash"
                    : nil
            )
            self.init(
                mode: method == "transcript" ? .local : .remote,
                remote: remote
            )
            legacyMethod = method
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(mode, forKey: .mode)
            try values.encode(remote, forKey: .remote)
            try values.encodeIfPresent(legacyMethod, forKey: .legacyMethod)
        }

        var detailLevel: SummaryDetailLevel? {
            SummaryDetailLevel.fromPersistedValue(remote.detail)
        }
    }

    var summary: Summary?
    var outputLanguage: SummaryLanguage
    var analysisLanguages: AnalysisLanguages

    @MainActor
    static func initialValues(from settings: AppSettings = .shared) -> Self {
        Self(
            outputLanguage: settings.llmSummaryLanguage,
            analysisLanguages: AnalysisLanguages(
                scope: settings.appLanguageScope,
                identifiers: settings.enabledLanguageIdentifiers.sorted()
            )
        )
    }

    struct Patch: Encodable, Sendable {
        var outputLanguage: SummaryLanguage?
        var analysisLanguages: AnalysisLanguages?
        var initialize: Bool?
        struct Summary: Encodable, Sendable {
            var mode: SummaryMode?
            var remote: Remote?
        }

        struct Remote: Encodable, Sendable {
            var detail: String?
            var model: String?
            var reasoningEffort: String?
            var transcriptionModel: String??
        }

        var summary: Summary?
    }

    struct Response: Decodable, Sendable {
        let settings: ServerAccountSettings?
    }
}

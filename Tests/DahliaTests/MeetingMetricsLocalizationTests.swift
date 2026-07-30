import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingMetricsLocalizationTests {
        private static let insightKeys = [
            "Microphone-source speech rate was around %@ characters per minute in this meeting.",
            "This is above the provisional beta reference value and is an estimate, not a measurement of clarity.",
            "Microphone-source speech accounted for about %@ of labelled speaking time.",
            "Microphone and system sources overlapped for about %@ of total talk time (%@).",
            "No notable pattern stood out in this meeting.",
            "Not enough transcript to summarise this meeting yet.",
            "Source labels cover too little of this transcript to compare sources.",
            "This is an estimate based on labelled audio-source activity.",
            "Meeting metrics could not be loaded.",
        ]

        private static let caveatKeys = [
            "Metrics are derived from audio sources, not from speaker identification.",
            "The microphone source is treated as you and the system source as the other participants.",
            "When echo cancellation is unavailable, system audio can leak into the microphone source and inflate overlap.",
            "Beta feature. Values are estimates and thresholds are provisional.",
        ]

        private static let recomputeKeys = [
            "Recalculate metrics",
            "Recalculating metrics…",
            "Metrics cannot be recalculated while recording. Try again after recording stops.",
            "This transcript has no audio-source labels, so sources cannot be compared. Recalculating will not change this.",
        ]

        @Test
        func localizationKeySetsMatch() throws {
            let english = try entries(language: "en")
            let japanese = try entries(language: "ja")
            #expect(Set(english.keys) == Set(japanese.keys))
            for key in Self.insightKeys + Self.caveatKeys + Self.recomputeKeys {
                #expect(english[key] != nil)
                #expect(japanese[key] != nil)
            }
        }

        @Test
        func insightCopyAvoidsProhibitedClaims() throws {
            let prohibited = ["割り込", "遮", "原因", "良い", "悪い", "改善すべき", "interrupt", "because", "should", "good", "bad"]
            for language in ["en", "ja"] {
                let values = try entries(language: language)
                for key in Self.insightKeys {
                    let value = try #require(values[key]?.lowercased())
                    for word in prohibited {
                        #expect(!value.contains(word.lowercased()))
                    }
                }
            }
        }

        @Test
        func caveatsExplicitlyDenySpeakerIdentification() throws {
            let english = try entries(language: "en")
            let japanese = try entries(language: "ja")
            #expect(english[Self.caveatKeys[0]]?.contains("not from speaker identification") == true)
            #expect(japanese[Self.caveatKeys[0]]?.contains("話者の識別は行っていません") == true)
        }

        @Test
        func languageSwitchReloadsMainActorLocalization() {
            let defaults = UserDefaults.standard
            let previous = defaults.string(forKey: AppLanguage.userDefaultsKey)
            defer {
                if let previous {
                    defaults.set(previous, forKey: AppLanguage.userDefaultsKey)
                } else {
                    defaults.removeObject(forKey: AppLanguage.userDefaultsKey)
                }
            }
            defaults.set(AppLanguage.en.rawValue, forKey: AppLanguage.userDefaultsKey)
            let english = L10n.meetingMetrics
            defaults.set(AppLanguage.ja.rawValue, forKey: AppLanguage.userDefaultsKey)
            let japanese = L10n.meetingMetrics
            #expect(english == "Meeting Metrics")
            #expect(japanese == "ミーティング指標")
        }

        @Test
        func interpolationUsesSupportedTokensOnly() throws {
            for language in ["en", "ja"] {
                let values = try entries(language: language)
                for key in Self.insightKeys {
                    let value = try #require(values[key])
                    let stripped = value.replacingOccurrences(of: "%@", with: "")
                        .replacingOccurrences(of: "%lld", with: "")
                    #expect(!stripped.contains("%"))
                }
            }
        }

        private func entries(language: String) throws -> [String: String] {
            let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
            let data = try String(contentsOfFile: path + "/Localizable.strings", encoding: .utf8)
            let expression = try NSRegularExpression(pattern: #"^\"((?:\\.|[^\"])*)\"\s*=\s*\"((?:\\.|[^\"])*)\";"#, options: .anchorsMatchLines)
            let range = NSRange(data.startIndex..., in: data)
            return expression.matches(in: data, range: range).reduce(into: [:]) { result, match in
                guard let keyRange = Range(match.range(at: 1), in: data),
                      let valueRange = Range(match.range(at: 2), in: data) else { return }
                result[String(data[keyRange])] = String(data[valueRange])
            }
        }
    }
#endif

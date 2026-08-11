import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

struct TranscriptTranslationLanguageTests {
    @Test
    func normalizesLocaleIdentifiersToLanguageCodes() {
        #expect(TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: "en_US") == "en")
        #expect(TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: "en-GB") == "en")
        #expect(TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: "ja_JP") == "ja")
    }

    @Test
    func skipsTranslationWhenSourceAndTargetLanguagesMatch() {
        #expect(
            !TranscriptTranslationLanguage.shouldTranslate(
                transcriptionLocaleIdentifier: "en_US",
                targetLanguageIdentifier: "en"
            )
        )
        #expect(
            !TranscriptTranslationLanguage.shouldTranslate(
                transcriptionLocaleIdentifier: "ja_JP",
                targetLanguageIdentifier: "ja"
            )
        )
        #expect(
            TranscriptTranslationLanguage.shouldTranslate(
                transcriptionLocaleIdentifier: "en_US",
                targetLanguageIdentifier: "ja"
            )
        )
    }

    @Test
    func localizesDisplayNamesForProvidedLocale() {
        #expect(TranscriptTranslationLanguage.displayName(for: "ja", locale: Locale(identifier: "en")) == "Japanese")
        #expect(TranscriptTranslationLanguage.displayName(for: "en", locale: Locale(identifier: "ja")) == "英語")
    }
}
#endif

#if canImport(XCTest)
import XCTest

final class TranscriptTranslationLanguageXCTests: XCTestCase {
    func testNormalizesLocaleIdentifiersToLanguageCodes() {
        XCTAssertEqual(TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: "en_US"), "en")
        XCTAssertEqual(TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: "en-GB"), "en")
        XCTAssertEqual(TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: "ja_JP"), "ja")
    }

    func testSkipsTranslationWhenSourceAndTargetLanguagesMatch() {
        XCTAssertFalse(
            TranscriptTranslationLanguage.shouldTranslate(
                transcriptionLocaleIdentifier: "en_US",
                targetLanguageIdentifier: "en"
            )
        )
        XCTAssertFalse(
            TranscriptTranslationLanguage.shouldTranslate(
                transcriptionLocaleIdentifier: "ja_JP",
                targetLanguageIdentifier: "ja"
            )
        )
        XCTAssertTrue(
            TranscriptTranslationLanguage.shouldTranslate(
                transcriptionLocaleIdentifier: "en_US",
                targetLanguageIdentifier: "ja"
            )
        )
    }

    func testLocalizesDisplayNamesForProvidedLocale() {
        XCTAssertEqual(
            TranscriptTranslationLanguage.displayName(for: "ja", locale: Locale(identifier: "en")),
            "Japanese"
        )
        XCTAssertEqual(
            TranscriptTranslationLanguage.displayName(for: "en", locale: Locale(identifier: "ja")),
            "英語"
        )
    }
}
#endif

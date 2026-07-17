import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

struct ErrorReportingServiceTests {
    @Test
    func resolveDSNUsesPlistValueForReleaseBuild() {
        let dsn = ErrorReportingService.resolveDSN(
            infoDictionary: ["SENTRY_DSN": "https://examplePublicKey@o0.ingest.sentry.io/1"],
            isDebugBuild: false
        )

        #expect(dsn == "https://examplePublicKey@o0.ingest.sentry.io/1")
    }

    @Test
    func resolveDSNIgnoresWhitespaceOnlyValues() {
        let dsn = ErrorReportingService.resolveDSN(
            infoDictionary: ["SENTRY_DSN": "   \n  "],
            isDebugBuild: false
        )

        #expect(dsn == nil)
    }

    @Test
    func resolveDSNDisablesSentryForDebugBuilds() {
        let dsn = ErrorReportingService.resolveDSN(
            infoDictionary: ["SENTRY_DSN": "https://examplePublicKey@o0.ingest.sentry.io/1"],
            isDebugBuild: true
        )

        #expect(dsn == nil)
    }

    @Test
    func resolveReleaseMetadataUsesBundleVersions() {
        let metadata = ErrorReportingService.resolveReleaseMetadata(infoDictionary: [
            "CFBundleIdentifier": "com.dahlia.app",
            "CFBundleShortVersionString": "0.3.1",
            "CFBundleVersion": "12",
        ])

        #expect(metadata == ErrorReportingService.ReleaseMetadata(
            name: "com.dahlia.app@0.3.1+12",
            distribution: "12"
        ))
    }

    @Test
    func resolveReleaseMetadataRequiresEveryBundleValue() {
        let metadata = ErrorReportingService.resolveReleaseMetadata(infoDictionary: [
            "CFBundleIdentifier": "com.dahlia.app",
            "CFBundleShortVersionString": "0.3.1",
        ])

        #expect(metadata == nil)
    }
}
#endif

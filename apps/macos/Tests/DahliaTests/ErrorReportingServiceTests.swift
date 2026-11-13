import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct ErrorReportingServiceTests {
        @Test
        func resolveDSNUsesExplicitPlistValue() {
            let dsn = ErrorReportingService.resolveDSN(
                infoDictionary: ["SENTRY_DSN": "https://examplePublicKey@o0.ingest.sentry.io/1"]
            )

            #expect(dsn == "https://examplePublicKey@o0.ingest.sentry.io/1")
        }

        @Test
        func resolveDSNIgnoresWhitespaceOnlyValues() {
            let dsn = ErrorReportingService.resolveDSN(
                infoDictionary: ["SENTRY_DSN": "   \n  "]
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

        @Test
        func sanitizedGoogleDiagnosticsContainOnlyAFixedCategory() {
            let error = ErrorReportingService.sanitizedError(for: .googleCalendar)

            #expect(error.domain == "com.dahlia.app.sanitized-diagnostic")
            #expect(error.code == 1)
            #expect(error.userInfo.keys.count == 1)
            #expect(error.localizedDescription == "google_calendar_error")
        }

        @Test
        func sanitizedContextDropsUnlistedAndFreeFormValues() {
            let context = ErrorReportingService.sanitizedContext([
                "source": "summaryGeneration",
                "locale": "en-US",
                "platformId": "private-event-id",
                "errorCode": "contains spaces",
                "fallbackCount": "3",
                "inferenceFailedCount": "meetingTitle",
            ])

            #expect(context == [
                "fallbackCount": "3",
                "source": "summaryGeneration",
                "locale": "en-US",
            ])
        }

        @Test
        func sanitizedContextRejectsContentShapedValuesOnAllowedKeys() {
            let context = ErrorReportingService.sanitizedContext([
                "source": "SecretProject",
                "audioSource": "customerName",
                "locale": "privateMeeting",
                "candidateScope": "Acme",
                "failureKind": "confidential",
                "errorCode": "transcriptText",
            ])

            #expect(context.isEmpty)
        }

        @Test
        func breadcrumbAllowlistDropsAutomaticSDKCategories() {
            #expect(ErrorReportingService.isAllowedBreadcrumbCategory("ui.screenshot_grid"))
            #expect(ErrorReportingService.isAllowedBreadcrumbCategory("runtime.automatic_screenshot"))
            #expect(!ErrorReportingService.isAllowedBreadcrumbCategory("app.lifecycle"))
            #expect(!ErrorReportingService.isAllowedBreadcrumbCategory("http"))
        }

        @Test
        func piInstallationDiagnosticsAllowOnlyFixedValues() {
            let context = PiInstallError(stage: .download, reason: .rateLimited, httpStatus: 429).diagnosticContext
            #expect(ErrorReportingService.sanitizedContext(context) == context)
            #expect(context == [
                "source": "piInstallation", "piInstallStage": "download",
                "piInstallReason": "rateLimited", "httpStatus": "429",
            ])
            for stage in PiInstallError.Stage.allCases {
                for reason in PiInstallError.Reason.allCases {
                    let context = PiInstallError(stage: stage, reason: reason).diagnosticContext
                    #expect(ErrorReportingService.sanitizedContext(context) == context)
                }
            }
            #expect(ErrorReportingService.sanitizedContext([
                "source": "piInstallation", "piInstallStage": "/Users/private",
                "piInstallReason": "privateMessage", "httpStatus": "999",
                "url": "https://private.example", "message": "secret", "version": "private",
            ]) == ["source": "piInstallation"])
            #expect(ErrorReportingService.sanitizedContext([
                "source": "summaryGeneration", "httpStatus": "403",
            ]) == ["source": "summaryGeneration"])
        }
    }
#endif

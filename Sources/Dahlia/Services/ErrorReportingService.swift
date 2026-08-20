import Foundation
@preconcurrency import Sentry

/// Sentry を用いたエラー報告サービス。
enum ErrorReportingService {
    private static let allowedSources: Set = [
        "additionalMeetingRowsObservation",
        "backupRestoreAudioCleanup",
        "backupRestoreRelaunch",
        "batchAudioPurge",
        "batchAudioPurgeRecovery",
        "batchLanguageDetectionFallback",
        "batchRecording",
        "batchTranscriptAudioFeatures",
        "batchTranscriptExport",
        "batchTranscription",
        "batchTranscriptionFailurePersistence",
        "batchTranscriptionQueue",
        "batchTranscriptionStartupRecovery",
        "batchTranscriptionTerminationPersistence",
        "calendarEventRecording",
        "calendarEventSelection",
        "calendarMeetingNotification",
        "calendarMeetingResolution",
        "customer_intelligence_ingestion_error",
        "deleteExportedScreenshots",
        "deleteScreenshots",
        "downloadScreenshot",
        "folderImport",
        "google_calendar_error",
        "google_docs_export_error",
        "google_drive_error",
        "google_drive_export_folder_error",
        "liveTranscription",
        "loadMeeting",
        "loadVaults",
        "macCalendar",
        "materializeDraftMeeting",
        "meetingContext",
        "meeting_conversation_metrics_error",
        "meetingNotificationAuthorization",
        "meetingReferenceObservation",
        "meetingSidebarObservation",
        "meetingSidebarPage",
        "meetingSidebarSearch",
        "microphoneMeetingNotification",
        "prepareAnalyzer",
        "projectCatalogObservation",
        "recordingAppendTarget",
        "registerVault",
        "removeVault",
        "selectedMeetingObservation",
        "startListening",
        "startTranscriptionPersistence",
        "stopRecordingSession",
        "stopTranscriptionPersistence",
        "summaryGeneration",
        "vaultSummaryExport",
        "vaultSummaryPathSync",
    ]
    private static let allowedAudioSources: Set = ["mic", "microphone", "system", "unknown"]
    private static let allowedCandidateScopes: Set = ["all", "selected"]
    private static let allowedFailureKinds: Set = [
        "recordingAudioPermanent",
        "recordingRecovery",
        "recordingStorage",
        "transcription",
        "transcriptionInterrupted",
        "transcriptionStalled",
    ]
    private static let allowedErrorCodes: Set = [
        "analysisDidNotAdvance",
        "analysisStalled",
        "audioFormatUnavailable",
        "invalidAudioRange",
        "languageDetectionAudioLoadingFailed",
        "languageDetectionFailed",
        "languageModelPreparationFailed",
        "noAutomaticLanguageCandidates",
        "unsupportedDetectedLanguage",
    ]
    private static let allowedLocaleIdentifiers = Set(Locale.availableIdentifiers)

    enum SanitizedCategory: String {
        case googleCalendar = "google_calendar_error"
        case googleDrive = "google_drive_error"
        case googleDriveExportFolder = "google_drive_export_folder_error"
        case googleDocsExport = "google_docs_export_error"
        case customerIntelligenceIngestion = "customer_intelligence_ingestion_error"
        case meetingConversationMetrics = "meeting_conversation_metrics_error"
    }

    enum AutomaticScreenshotStage: String {
        case fingerprint
        case encoding
        case persistence
    }

    struct ReleaseMetadata: Equatable {
        let name: String
        let distribution: String
    }

    private static let dsnInfoKey = "SENTRY_DSN"
    private nonisolated(unsafe) static var isEnabled = false

    static func start() {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]
        guard let dsn = resolveDSN(infoDictionary: infoDictionary, isDebugBuild: isDebugBuild) else { return }
        let releaseMetadata = resolveReleaseMetadata(infoDictionary: infoDictionary)

        isEnabled = true
        SentrySDK.start { options in
            options.dsn = dsn
            options.enableCrashHandler = true
            options.enableAutoPerformanceTracing = false
            options.enableCaptureFailedRequests = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.tracesSampleRate = 0
            options.sendDefaultPii = false
            options.beforeSend = { event in
                event.extra = nil
                event.request = nil
                event.user = nil
                return event
            }
            options.beforeBreadcrumb = { breadcrumb in
                isAllowedBreadcrumbCategory(breadcrumb.category) ? breadcrumb : nil
            }
            if let releaseMetadata {
                options.releaseName = releaseMetadata.name
                options.dist = releaseMetadata.distribution
            }
            #if DEBUG
                options.environment = "debug"
            #else
                options.environment = "production"
            #endif
        }
    }

    static func capture(_: Error, context: [String: String] = [:]) {
        capture(context: context)
    }

    static func captureSanitized(_ category: SanitizedCategory) {
        capture(context: ["source": category.rawValue])
    }

    private static func capture(context: [String: String]) {
        guard isEnabled else { return }
        let sanitizedContext = sanitizedContext(context)
        let category = sanitizedContext["source"] ?? "technical_error"
        SentrySDK.capture(error: sanitizedError(description: category)) { scope in
            for (key, value) in sanitizedContext {
                scope.setTag(value: value, key: key)
            }
        }
    }

    static func sanitizedError(for category: SanitizedCategory) -> NSError {
        sanitizedError(description: category.rawValue)
    }

    private static func sanitizedError(description: String) -> NSError {
        NSError(
            domain: "com.dahlia.app.sanitized-diagnostic",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    static func sanitizedContext(_ context: [String: String]) -> [String: String] {
        context.filter { key, value in
            isAllowedContextValue(value, for: key)
        }
    }

    private static func isAllowedContextValue(_ value: String, for key: String) -> Bool {
        switch key {
        case "source":
            allowedSources.contains(value)
        case "audioSource":
            allowedAudioSources.contains(value)
        case "locale":
            allowedLocaleIdentifiers.contains(value)
                || allowedLocaleIdentifiers.contains(value.replacingOccurrences(of: "-", with: "_"))
        case "candidateScope":
            allowedCandidateScopes.contains(value)
        case "candidateLanguageCount", "fallbackCount", "inferenceFailedCount":
            value.allSatisfy(\.isNumber) && (Int(value).map { (0 ... 999).contains($0) } ?? false)
        case "failureKind":
            allowedFailureKinds.contains(value)
        case "errorCode":
            allowedErrorCodes.contains(value)
        default:
            false
        }
    }

    static func isAllowedBreadcrumbCategory(_ category: String) -> Bool {
        category == "runtime.automatic_screenshot" || category == "ui.screenshot_grid"
    }

    static func recordScreenshotCollectionState(countBucket: Int, minimumWidthBucket: Int) {
        guard isEnabled else { return }
        let breadcrumb = Breadcrumb(level: .info, category: "ui.screenshot_grid")
        breadcrumb.type = "state"
        breadcrumb.data = [
            "backend": "nscollectionview",
            "count_bucket": String(countBucket),
            "minimum_width_bucket": String(minimumWidthBucket),
        ]
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    static func recordSlowAutomaticScreenshotStage(
        _ stage: AutomaticScreenshotStage,
        durationMilliseconds: Int
    ) {
        guard isEnabled, durationMilliseconds >= 500 else { return }
        let breadcrumb = Breadcrumb(level: .warning, category: "runtime.automatic_screenshot")
        breadcrumb.type = "state"
        breadcrumb.data = [
            "event": "slow_stage",
            "stage": stage.rawValue,
            "duration_bucket_ms": String(automaticScreenshotDurationBucket(durationMilliseconds)),
        ]
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    static func recordAutomaticScreenshotStreamRestart() {
        guard isEnabled else { return }
        let breadcrumb = Breadcrumb(level: .warning, category: "runtime.automatic_screenshot")
        breadcrumb.type = "state"
        breadcrumb.data = ["event": "stream_restart"]
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    static func automaticScreenshotDurationBucket(_ milliseconds: Int) -> Int {
        switch milliseconds {
        case ..<1000: 500
        case ..<2000: 1000
        case ..<5000: 2000
        default: 5000
        }
    }

    static func resolveDSN(infoDictionary: [String: Any], isDebugBuild: Bool) -> String? {
        guard !isDebugBuild else { return nil }
        return trimmedString(for: dsnInfoKey, in: infoDictionary)
    }

    static func resolveReleaseMetadata(infoDictionary: [String: Any]) -> ReleaseMetadata? {
        guard let bundleIdentifier = trimmedString(for: "CFBundleIdentifier", in: infoDictionary),
              let marketingVersion = trimmedString(for: "CFBundleShortVersionString", in: infoDictionary),
              let buildVersion = trimmedString(for: "CFBundleVersion", in: infoDictionary)
        else {
            return nil
        }

        return ReleaseMetadata(
            name: "\(bundleIdentifier)@\(marketingVersion)+\(buildVersion)",
            distribution: buildVersion
        )
    }

    private static func trimmedString(for key: String, in dictionary: [String: Any]) -> String? {
        guard let rawValue = dictionary[key] as? String else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }
}

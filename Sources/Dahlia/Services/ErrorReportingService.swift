import Foundation
@preconcurrency import Sentry

/// Sentry を用いたエラー報告サービス。
enum ErrorReportingService {
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

    static func capture(_ error: Error, context: [String: String] = [:]) {
        guard isEnabled else { return }
        SentrySDK.capture(error: error) { scope in
            for (key, value) in context {
                scope.setTag(value: value, key: key)
            }
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

import Foundation

public enum DahliaRuntimeProfile: String, Sendable {
    case production
    case development
}

public enum DahliaApplicationSupport {
    public static let profileEnvironmentKey = "DAHLIA_RUNTIME_PROFILE"

    public static func profile(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        embeddedProfile: String? = Bundle.main.object(forInfoDictionaryKey: profileEnvironmentKey) as? String
    ) -> DahliaRuntimeProfile {
        profile(
            environment: environment,
            embeddedProfile: embeddedProfile,
            isDebugBuild: _isDebugAssertConfiguration()
        )
    }

    public static func profile(
        environment: [String: String],
        embeddedProfile: String?,
        isDebugBuild: Bool
    ) -> DahliaRuntimeProfile {
        if isDebugBuild
            || embeddedProfile == DahliaRuntimeProfile.development.rawValue
            || environment[profileEnvironmentKey] == DahliaRuntimeProfile.development.rawValue {
            return .development
        }
        return .production
    }

    public static func directoryURL(
        applicationSupportDirectory: URL = .applicationSupportDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        directoryURL(profile: profile(environment: environment), applicationSupportDirectory: applicationSupportDirectory)
    }

    public static func directoryURL(
        profile: DahliaRuntimeProfile,
        applicationSupportDirectory: URL = .applicationSupportDirectory
    ) -> URL {
        applicationSupportDirectory.appending(
            path: directoryName(for: profile),
            directoryHint: .isDirectory
        )
    }

    public static var currentDirectoryURL: URL {
        directoryURL()
    }

    private static func directoryName(for profile: DahliaRuntimeProfile) -> String {
        switch profile {
        case .production:
            "Dahlia"
        case .development:
            "Dahlia-Development"
        }
    }
}

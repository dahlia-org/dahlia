import Foundation

public enum DahliaRuntimeProfile: String, Sendable {
    case production
    case development
}

public enum DahliaApplicationSupport {
    public static let profileEnvironmentKey = "DAHLIA_RUNTIME_PROFILE"

    public static func profile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DahliaRuntimeProfile {
        #if DEBUG
            guard environment[profileEnvironmentKey] == DahliaRuntimeProfile.development.rawValue else {
                return .production
            }
            return .development
        #else
            return .production
        #endif
    }

    public static func directoryURL(
        applicationSupportDirectory: URL = .applicationSupportDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        applicationSupportDirectory.appending(
            path: directoryName(for: profile(environment: environment)),
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

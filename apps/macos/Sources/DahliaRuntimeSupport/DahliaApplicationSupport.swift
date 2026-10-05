import Foundation

public enum DahliaRuntimeProfile: String, Sendable {
    case production
    case development
}

public enum DahliaApplicationSupport {
    public static let profileEnvironmentKey = "DAHLIA_RUNTIME_PROFILE"
    public static let developmentDirectoryKey = "DAHLIA_DEVELOPMENT_DIRECTORY"

    /// `run-dev.sh` embeds this in worktree builds. Helpers in Contents/Helpers read the same Info.plist as the app.
    public static let embeddedDevelopmentDirectory: URL? = Bundle.main.executableURL
        .flatMap(developmentDirectory(executableURL:))

    public static func profile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DahliaRuntimeProfile {
        profile(
            environment: environment,
            embeddedProfile: Bundle.main.object(forInfoDictionaryKey: profileEnvironmentKey) as? String,
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

    public static func developmentDirectory(executableURL: URL) -> URL? {
        let infoURL = executableURL.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Info.plist")
        // A relative path would resolve against each process's working directory, splitting the app from its helpers.
        guard let path = NSDictionary(contentsOf: infoURL)?[developmentDirectoryKey] as? String,
              path.hasPrefix("/")
        else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    public static func directoryURL(
        applicationSupportDirectory: URL = .applicationSupportDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        directoryURL(profile: profile(environment: environment), applicationSupportDirectory: applicationSupportDirectory)
    }

    public static func directoryURL(
        profile: DahliaRuntimeProfile,
        developmentDirectory: URL? = embeddedDevelopmentDirectory,
        applicationSupportDirectory: URL = .applicationSupportDirectory
    ) -> URL {
        switch profile {
        case .production:
            applicationSupportDirectory.appending(path: "Dahlia", directoryHint: .isDirectory)
        case .development:
            developmentDirectory
                ?? applicationSupportDirectory.appending(path: "Dahlia-Development", directoryHint: .isDirectory)
        }
    }

    public static var currentDirectoryURL: URL {
        directoryURL()
    }
}

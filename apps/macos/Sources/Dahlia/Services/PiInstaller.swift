import CryptoKit
import DahliaRuntimeSupport
import Foundation

/// Installs Pi for Macs without a `pi` of their own, as Pi's own installer (`pi.dev/install.sh`) does but with Bun:
/// macOS ships no JavaScript runtime, and Pi's release binaries are built with Bun. Dahlia downloads that Bun, checks it
/// against a pinned SHA-256, and installs Pi's npm package with it as a Bun global package, from the `package.json`
/// (with its overrides) and `package-lock.json` that pi.dev publishes for each release, without install scripts.
///
/// `directoryURL` is Bun's `BUN_INSTALL` (`Application Support/<profile>/bun`), laid out as by `bun install -g`: Pi in
/// `install/global`, and `bin` with `bun` and `pi`, Bun's link to Pi's entry point. Since Pi runs from Bun's global
/// folder, `pi update` updates it with `bun install -g`, as for any Bun install of Pi, and Dahlia's update runs the same
/// command with the registry's latest release; Dahlia keeps no versions of its own. The entry point starts with
/// `#!/usr/bin/env node` and macOS has no Node, so Dahlia runs it with Bun (`PiBundle.processCommand`). The npm package
/// keeps Pi's modules unbundled, so extensions such as pi-mcp-elicitation can load Pi's MCP runtime.
enum PiInstaller {
    /// `Dahlia --install-pi [version]` installs a release from the command line.
    static let commandLineFlag = "--install-pi"
    private static let installerAPIURL = URL(string: "https://pi.dev/api/installer/releases")!
    static let packageName = "@earendil-works/pi-coding-agent"
    // shortcut: an installed Bun is kept when this changes; compare `bun --version` once a newer Bun is needed.
    /// The Bun of Pi's own release binaries.
    static let bunVersion = "1.4.4"
    /// The API's asset URL of `bun-darwin-aarch64.zip`; github.com's download URL has answered HTTP 504.
    private static let bunAssetURL = URL(string: "https://api.github.com/repos/oven-sh/bun/releases/assets/665260236")!
    private static let bunSHA256 = "c240d7f0ccb90c263a849fcdb09b7ee62630d921348ed6aafda86b9d577bc510"

    /// Beside Dahlia's data rather than in `~/.dahlia`, which holds what users read and edit (Pi's home, agents); chat's
    /// sandbox can neither read nor write it.
    static var directoryURL: URL {
        DahliaApplicationSupport.currentDirectoryURL.appending(path: "bun", directoryHint: .isDirectory)
    }

    /// `Application Support/<profile>/bun/bin/pi`. Accounts run it when Dahlia-managed Pi is enabled in Settings.
    static var executableURL: URL { binURL(in: directoryURL) }

    /// The Bun that runs Dahlia-managed Pi.
    static var bunURL: URL { directoryURL.appending(path: "bin/bun") }

    /// Releases before Bun installs kept Pi's binary in `Application Support/<profile>/bin/pi`; it runs until Pi is
    /// installed again.
    static var legacyExecutableURL: URL {
        DahliaApplicationSupport.currentDirectoryURL.appending(path: "bin/pi")
    }

    /// The registry Pi installs and updates from unless the account sets another. Not shown in the UI.
    private static let defaultRegistry = "https://npm-proxy.cloud.databricks.com/"

    /// The npm registry (a proxy, for example) Dahlia-managed Pi installs and updates from; empty is `defaultRegistry`.
    static func registryDefaultsKey() -> String {
        "piNpmRegistry.\(AppAccount.key)"
    }

    static func registry(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: registryDefaultsKey()) ?? ""
    }

    /// The registry setting, or `defaultRegistry` when empty. Only an http(s) URL is accepted, so the field cannot add
    /// other settings to `.npmrc`.
    static func registryURL(_ registry: String) throws -> URL {
        let entered = registry.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = entered.isEmpty ? defaultRegistry : entered
        guard !value.contains(where: \.isWhitespace), let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased()), url.host() != nil
        else { throw PiInstallError(stage: .download, reason: .invalidRegistry) }
        return url
    }

    /// The `.npmrc` of Bun's global folder, which Bun reads for Dahlia's installs and for `bun install -g` in `pi update`
    /// alike, before `~/.npmrc`.
    static func npmrc(registry: String) throws -> Data {
        try Data("registry=\(registryURL(registry).absoluteString)\n".utf8)
    }

    struct Release: Sendable {
        let version: String
    }

    /// The `dist-tags` of Pi's package in the registry.
    struct Packument: Decodable {
        let distTags: [String: String]

        private enum CodingKeys: String, CodingKey {
            case distTags = "dist-tags"
        }
    }

    /// The Pi in Bun's global folder, whichever installed it (Dahlia or `pi update`), or nil without its `bin/pi`.
    static func installedVersion(in directory: URL = directoryURL) -> String? {
        guard CommandLineToolLocator.isExecutableFile(atPath: binURL(in: directory).path),
              let data = try? Data(contentsOf: globalURL(in: directory).appending(path: "node_modules/\(packageName)/package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? String
    }

    /// `version` (a leading `v` is optional), or the latest release the registry serves. pi.dev may announce a release
    /// before a proxy registry lets it through (a proxy has answered HTTP 403 for a day-old release), so the registry
    /// decides; pi.dev keeps the lockfile of every release.
    @concurrent
    static func release(
        version: String? = nil,
        session: URLSession = .shared,
        registry: String = registry(),
        reportFailure: @Sendable (PiInstallError) -> Void = ErrorReportingService.capturePiInstallation
    ) async throws -> Release {
        if let version { return Release(version: version.hasPrefix("v") ? String(version.dropFirst()) : version) }
        do {
            var request = try URLRequest(url: registryURL(registry).appending(path: packageName))
            request.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            try validateResponse(response, stage: .release)
            guard let latest = try? JSONDecoder().decode(Packument.self, from: data).distTags["latest"] else {
                throw PiInstallError(stage: .release, reason: .invalidRelease)
            }
            return Release(version: latest)
        } catch {
            throw reportedFailure(error, stage: .release, reporter: reportFailure)
        }
    }

    /// Downloads Bun if needed and the release's lockfile, then installs the release in Bun's global folder.
    @concurrent
    static func install(
        _ release: Release,
        into directory: URL = directoryURL,
        session: URLSession = .shared,
        environment: [String: String] = installEnvironment(),
        registry: String = registry(),
        reportFailure: @Sendable (PiInstallError) -> Void = ErrorReportingService.capturePiInstallation
    ) async throws {
        var stage = PiInstallError.Stage.activation
        do {
            guard isValidVersion(release.version) else { throw PiInstallError(stage: .release, reason: .invalidRelease) }
            let npmrc = try npmrc(registry: registry)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            stage = .download
            let bun = try await bunExecutable(in: directory, session: session)
            let releaseURL = installerAPIURL.appending(path: release.version)
            var files: [Data] = []
            for name in ["package.json", "package-lock.json"] {
                let (data, response) = try await session.data(from: releaseURL.appending(path: name))
                try validateResponse(response, stage: .download)
                files.append(data)
            }
            let packageJSON = files[0]
            let packageLock = files[1]
            try await withCancellableProcess { process in
                try install(
                    version: release.version, packageJSON: packageJSON, packageLock: packageLock, npmrc: npmrc, bun: bun,
                    environment: environment, into: directory, process: process
                )
            }
        } catch {
            throw reportedFailure(error, stage: stage, reporter: reportFailure)
        }
    }

    /// The user's variables for this account (a proxy or an npm registry, for example) reach the package install.
    static func installEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.merging(PiLaunchSettings.load().environment {
            KeychainService.load(key: PiLaunchSettings.secretKey(id: $0))
        }) { $1 }
    }

    /// `bin/bun` in Bun's folder, downloaded once and checked against the pinned SHA-256.
    private static func bunExecutable(in directory: URL, session: URLSession) async throws -> URL {
        let url = directory.appending(path: "bin/bun")
        if CommandLineToolLocator.isExecutableFile(atPath: url.path) { return url }
        var request = URLRequest(url: bunAssetURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (archive, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: archive) }
        try validateResponse(response, stage: .download)
        try installBun(archive: archive, sha256: bunSHA256, to: url)
        return url
    }

    /// Checks the Bun archive's SHA-256 and extracts its executable to `url`.
    static func installBun(archive: URL, sha256: String, to url: URL) throws {
        var stage = PiInstallError.Stage.verification
        do {
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else {
                throw PiInstallError(stage: .verification, reason: .checksumMismatch)
            }
            stage = .extraction
            let fileManager = FileManager.default
            let folder = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let staging = folder.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: staging) }
            guard run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, staging.path]) != nil else {
                throw PiInstallError(stage: .extraction, reason: .extractionFailed)
            }
            let extracted = staging.appending(path: "bun-darwin-aarch64/bun")
            guard CommandLineToolLocator.isExecutableFile(atPath: extracted.path) else {
                throw PiInstallError(stage: .extraction, reason: .executableMissing)
            }
            // Another install may have moved its copy in first; either is the same verified file.
            if !CommandLineToolLocator.isExecutableFile(atPath: url.path) {
                try? fileManager.removeItem(at: url)
                try fileManager.moveItem(at: extracted, to: url)
            }
        } catch {
            throw PiInstallError.wrapping(error, stage: stage)
        }
    }

    /// Installs Pi from the release's `package.json` and `package-lock.json` with `bun` in a staging folder, checks that it
    /// runs, and then replaces Bun's global folder with it and links `bin/pi` as `bun install -g` does; a failure keeps
    /// the installed Pi.
    static func install(
        version: String,
        packageJSON: Data,
        packageLock: Data,
        npmrc: Data,
        bun: URL,
        environment: [String: String],
        into directory: URL,
        process: Process = Process()
    ) throws {
        var stage = PiInstallError.Stage.download
        do {
            guard isValidVersion(version) else { throw PiInstallError(stage: .release, reason: .invalidRelease) }
            let fileManager = FileManager.default
            let install = directory.appending(path: "install", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: install, withIntermediateDirectories: true)
            let staging = install.appending(path: ".global-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: staging) }
            try packageJSON.write(to: staging.appending(path: "package.json"))
            try lockWithoutTarballURLs(packageLock).write(to: staging.appending(path: "package-lock.json"))
            try npmrc.write(to: staging.appending(path: ".npmrc"))
            var bunEnvironment = environment
            bunEnvironment["BUN_INSTALL"] = directory.path
            guard run(
                bun,
                ["install", "--ignore-scripts", "--production", "--no-progress"],
                cwd: staging,
                environment: bunEnvironment,
                process: process
            ) != nil
            else { throw PiInstallError(stage: .download, reason: .packageInstallFailed) }

            stage = .extraction
            let package = "node_modules/\(packageName)"
            guard let manifest = try? JSONSerialization.jsonObject(with: Data(contentsOf: staging.appending(path: "\(package)/package.json"))),
                  let entry = ((manifest as? [String: Any])?["bin"] as? [String: String])?["pi"]
            else { throw PiInstallError(stage: .extraction, reason: .executableMissing) }
            let piEnvironment = environment.merging(["PI_OFFLINE": "1", "PI_TELEMETRY": "0"]) { $1 }
            let runs = run(bun, [staging.appending(path: "\(package)/\(entry)").path, "--version"], environment: piEnvironment)
            guard runs?.trimmingCharacters(in: .whitespacesAndNewlines) == version else {
                throw PiInstallError(stage: .extraction, reason: .executableMissing)
            }

            stage = .activation
            try withInstallLock(in: directory) {
                try Task.checkCancellation()
                let global = globalURL(in: directory)
                let previous = install.appending(path: ".previous-\(UUID().uuidString)", directoryHint: .isDirectory)
                let link = binURL(in: directory)
                try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                let pendingLink = link.deletingLastPathComponent().appending(path: ".pi-\(UUID())")
                defer { try? fileManager.removeItem(at: pendingLink) }
                try fileManager.createSymbolicLink(atPath: pendingLink.path, withDestinationPath: "../install/global/\(package)/\(entry)")
                let hadPrevious = fileManager.fileExists(atPath: global.path)
                if hadPrevious { try fileManager.moveItem(at: global, to: previous) }
                var moved = false
                do {
                    try fileManager.moveItem(at: staging, to: global)
                    moved = true
                    try Task.checkCancellation()
                    guard rename(pendingLink.path, link.path) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                } catch {
                    if moved { try fileManager.removeItem(at: global) }
                    if hadPrevious { try fileManager.moveItem(at: previous, to: global) }
                    throw error
                }
                try? fileManager.removeItem(at: previous)
            }
        } catch {
            throw PiInstallError.wrapping(error, stage: stage)
        }
    }

    /// Bun fetches a lockfile's tarball URLs as written, where npm uses the configured registry (`.npmrc`, often a proxy).
    /// Without them Bun resolves the same versions, checked by their integrity, from the configured registry.
    static func lockWithoutTarballURLs(_ data: Data) throws -> Data {
        guard var lock = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var packages = lock["packages"] as? [String: [String: Any]]
        else { throw PiInstallError(stage: .download, reason: .invalidRelease) }
        for key in packages.keys {
            packages[key]?.removeValue(forKey: "resolved")
        }
        lock["packages"] = packages
        return try JSONSerialization.data(withJSONObject: lock, options: [.sortedKeys])
    }

    /// Updates Pi in Bun's global folder to the latest release the registry serves, with `bun install -g` as `pi update`
    /// does. `pi update` takes its version from pi.dev, which a proxy registry may not let through yet. A registry
    /// behind the installed version does not downgrade it. Returns the version installed afterwards.
    @concurrent
    static func update(
        in directory: URL = directoryURL,
        session: URLSession = .shared,
        environment: [String: String] = installEnvironment(),
        registry: String = registry(),
        reportFailure: @Sendable (PiInstallError) -> Void = ErrorReportingService.capturePiInstallation
    ) async throws -> String {
        let release = try await release(session: session, registry: registry, reportFailure: reportFailure)
        do {
            guard isValidVersion(release.version) else { throw PiInstallError(stage: .release, reason: .invalidRelease) }
            let global = globalURL(in: directory)
            // The registry set since the last install applies to this update and later `pi update`s in a terminal.
            let npmrc = try npmrc(registry: registry)
            let bun = try await bunExecutable(in: directory, session: session)
            var bunEnvironment = environment
            bunEnvironment["BUN_INSTALL"] = directory.path
            let arguments = ["install", "-g", "--ignore-scripts", "--minimum-release-age=0", "--no-progress", "\(packageName)@\(release.version)"]
            let environment = bunEnvironment
            return try await withCancellableProcess { process in
                try withInstallLock(in: directory) {
                    try Task.checkCancellation()
                    try npmrc.write(to: global.appending(path: ".npmrc"), options: .atomic)
                    if let installed = installedVersion(in: directory), release.version.compare(installed, options: .numeric) != .orderedDescending {
                        return installed
                    }
                    guard run(bun, arguments, environment: environment, process: process) != nil, installedVersion(in: directory) == release.version
                    else { throw PiInstallError(stage: .download, reason: .packageInstallFailed) }
                    return release.version
                }
            }
        } catch {
            throw reportedFailure(error, stage: .download, reporter: reportFailure)
        }
    }

    /// The command's output, or nil when it fails. A file drains the output without pipe deadlocks.
    @concurrent
    static func withCancellableProcess<T: Sendable>(_ operation: @Sendable (Process) throws -> T) async throws -> T {
        let process = Process()
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let result = try operation(process)
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func run(
        _ executable: URL, _ arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil, process: Process = Process()
    ) -> String? {
        guard !Task.isCancelled else { return nil }
        let output = FileManager.default.temporaryDirectory.appending(path: "dahlia-pi-install-\(UUID())")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forUpdating: output)
        else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        guard (try? process.run()) != nil else { return nil }
        // Cancellation can arrive between the handler's isRunning check and run().
        if Task.isCancelled, process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard process.terminationStatus == 0, (try? handle.seek(toOffset: 0)) != nil else { return nil }
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    static func validateResponse(_ response: URLResponse, stage: PiInstallError.Stage) throws {
        guard let http = response as? HTTPURLResponse else { throw PiInstallError(stage: stage, reason: .invalidResponse) }
        guard http.statusCode != 200 else { return }
        let rateLimited = http.statusCode == 429 || (http.statusCode == 403
            && (http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || http.value(forHTTPHeaderField: "Retry-After") != nil))
        throw PiInstallError(stage: stage, reason: rateLimited ? .rateLimited : .http, httpStatus: http.statusCode)
    }

    /// Report once at each public network operation; cancellation is not an installation failure.
    static func reportedFailure(
        _ error: Error, stage: PiInstallError.Stage, reporter: (PiInstallError) -> Void
    ) -> Error {
        if Task.isCancelled { return CancellationError() }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return error }
        let failure = PiInstallError.wrapping(error, stage: stage)
        reporter(failure)
        return failure
    }

    /// Settings, the setup tour, and `--install-pi` share the folder, so replacing Bun's global folder and writing the
    /// launcher run one install at a time, across processes too.
    static func withInstallLock<T>(in directory: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appending(path: ".lock").path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Closing the descriptor releases the lock, as does the process exiting.
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body()
    }

    private static func binURL(in directory: URL) -> URL {
        directory.appending(path: "bin/pi")
    }

    private static func globalURL(in directory: URL) -> URL {
        directory.appending(path: "install/global", directoryHint: .isDirectory)
    }

    /// The version names a folder, so it must not contain a path separator or be `.` or `..`.
    private static func isValidVersion(_ version: String) -> Bool {
        !version.isEmpty && !version.hasPrefix(".")
            && version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
    }

    /// Runs `Dahlia --install-pi [version]` and exits; installs the latest release without a version.
    static func runCommandLine(_ arguments: [String]) -> Never {
        ErrorReportingService.start()
        Task.detached {
            do {
                let release = try await release(version: arguments.first)
                try await install(release)
                print(L10n.piInstalled(release.version))
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}

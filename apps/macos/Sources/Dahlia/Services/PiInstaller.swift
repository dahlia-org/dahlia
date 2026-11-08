import CryptoKit
import DahliaRuntimeSupport
import Foundation

/// Installs and updates Pi from its GitHub releases into Dahlia's folder, for Macs without a `pi` of their own.
///
/// Each release is extracted to `releases/<version>/`, and the `pi` entrypoint is a symlink to the current release's
/// executable. Pi resolves its resources from the link's target, so processes already running keep their release.
enum PiInstaller {
    /// `Dahlia --install-pi [version]` installs a release from the command line, for `PI_SELF_UPDATE_COMMAND`.
    static let commandLineFlag = "--install-pi"
    private static let releasesAPIURL = URL(string: "https://api.github.com/repos/earendil-works/pi/releases")!
    private static let assetName = "pi-darwin-arm64.tar.gz"

    static var directoryURL: URL {
        DahliaApplicationSupport.currentDirectoryURL.appending(path: "Pi", directoryHint: .isDirectory)
    }

    /// An account runs this once Agents settings sets it as the account's path.
    static var executableURL: URL { entrypointURL(in: directoryURL) }

    struct Release: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
            let browserDownloadURL: URL
            /// `sha256:<hex>`, computed by GitHub.
            let digest: String?

            private enum CodingKeys: String, CodingKey {
                case name, digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

        private enum CodingKeys: String, CodingKey {
            case assets
            case tagName = "tag_name"
        }
    }

    /// The release the entrypoint points at, or nil when Dahlia has not installed Pi.
    static func installedVersion(in directory: URL = directoryURL) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: entrypointURL(in: directory).path)
        else { return nil }
        let components = target.split(separator: "/")
        return components.count == 3 && components[0] == "releases" ? String(components[1]) : nil
    }

    /// The latest release, or the one tagged `v<version>`; a leading `v` in `version` is optional.
    @concurrent
    static func release(version: String? = nil) async throws -> Release {
        let tag = version.map { $0.hasPrefix("v") ? $0 : "v\($0)" }
        let url = releasesAPIURL.appending(path: tag.map { "tags/\($0)" } ?? "latest")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PiInstallError.downloadFailed }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Downloads the release's macOS arm64 archive unless it is already extracted, then points the entrypoint at it.
    @concurrent
    static func install(_ release: Release, into directory: URL = directoryURL) async throws {
        guard isValidVersion(release.version) else { throw PiInstallError.downloadFailed }
        if try withInstallLock(in: directory, { try activateIfExtracted(release.version, in: directory) }) { return }
        guard let asset = release.assets.first(where: { $0.name == assetName }),
              let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw PiInstallError.downloadFailed
        }
        let (archive, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PiInstallError.downloadFailed }
        try install(archive: archive, sha256: String(digest.dropFirst("sha256:".count)), version: release.version, into: directory)
    }

    /// Checks the archive's SHA-256, extracts it to `releases/<version>`, and activates it; a failure keeps the current Pi.
    static func install(archive: URL, sha256: String, version: String, into directory: URL) throws {
        guard isValidVersion(version) else { throw PiInstallError.downloadFailed }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else {
            throw PiInstallError.downloadFailed
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        // bsdtar strips leading `/` and refuses entries containing `..`.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        let extracted = staging.appending(path: "pi", directoryHint: .isDirectory)
        guard tar.terminationStatus == 0,
              CommandLineToolLocator.isExecutableFile(atPath: extracted.appending(path: "pi").path) else {
            throw PiInstallError.downloadFailed
        }
        try withInstallLock(in: directory) {
            // Release folders appear only by this move, so an existing one is complete; the entrypoint may point at it.
            if try !activateIfExtracted(version, in: directory) {
                let release = releaseURL(version, in: directory)
                try fileManager.createDirectory(at: release.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: extracted, to: release)
                try activate(version, in: directory)
            }
        }
    }

    /// Under the install lock, activates `version` when it is already extracted.
    private static func activateIfExtracted(_ version: String, in directory: URL) throws -> Bool {
        guard CommandLineToolLocator.isExecutableFile(atPath: releaseURL(version, in: directory).appending(path: "pi").path)
        else { return false }
        try activate(version, in: directory)
        return true
    }

    /// Settings and `--install-pi` share the folder, so checking a release, moving it in, swapping the entrypoint, and
    /// removing old releases run one install at a time, across processes too.
    static func withInstallLock<T>(in directory: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appending(path: ".lock").path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Closing the descriptor releases the lock, as does the process exiting.
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body()
    }

    /// Under the install lock, swaps the entrypoint in one rename, then removes releases that are neither this one, the
    /// previous one, nor run by a live process. Pi loads resources from its release folder while it runs, and the
    /// previous release covers a process that resolved the old link but has not finished starting. Reactivating the
    /// current release removes nothing, since its previous release is not known.
    private static func activate(_ version: String, in directory: URL) throws {
        let previous = installedVersion(in: directory)
        let link = directory.appending(path: ".pi-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "releases/\(version)/pi")
        guard rename(link.path, entrypointURL(in: directory).path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: link)
            throw error
        }
        guard previous != version else { return }
        let releases = directory.appending(path: "releases", directoryHint: .isDirectory)
        let kept = releasesInUse(in: releases, executablePaths: runningExecutablePaths()).union([version, previous].compactMap(\.self))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: releases.path)) ?? [] where !kept.contains(name) {
            try? FileManager.default.removeItem(at: releases.appending(path: name))
        }
    }

    /// The release folders, by name, that contain one of `executablePaths`.
    static func releasesInUse(in releases: URL, executablePaths: [String]) -> Set<String> {
        // Process paths are real paths, such as /private/var for /var.
        guard let root = realpath(releases.path, nil) else { return [] }
        defer { free(root) }
        let prefix = String(cString: root) + "/"
        return Set(executablePaths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count).prefix { $0 != "/" }) })
    }

    /// The executable of every process this user can inspect, as the real path it was started from.
    static func runningExecutablePaths() -> [String] {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(max(0, Int(count))).compactMap { pid in
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    private static func entrypointURL(in directory: URL) -> URL { directory.appending(path: "pi") }

    private static func releaseURL(_ version: String, in directory: URL) -> URL {
        directory.appending(path: "releases/\(version)", directoryHint: .isDirectory)
    }

    /// The version names a folder, so it must not contain a path separator or be `.` or `..`.
    private static func isValidVersion(_ version: String) -> Bool {
        !version.isEmpty && !version.hasPrefix(".")
            && version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
    }

    /// Runs `Dahlia --install-pi [version]` and exits; installs the latest release without a version.
    static func runCommandLine(_ arguments: [String]) -> Never {
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

enum PiInstallError: LocalizedError {
    case downloadFailed

    var errorDescription: String? { L10n.piDownloadFailed }
}

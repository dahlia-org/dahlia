import CryptoKit
import Foundation
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @Suite(.serialized)
    struct PiInstallerTests {
        @Test
        func httpFailuresDistinguishRateLimitsFromAccessDenials() throws {
            let url = try #require(URL(string: "https://example.test/private"))
            let cases: [(Int, [String: String], PiInstallError.Reason)] = [
                (403, [:], .http), (404, [:], .http), (504, [:], .http),
                (403, ["X-RateLimit-Remaining": "0"], .rateLimited),
                (403, ["Retry-After": "60"], .rateLimited), (429, [:], .rateLimited),
            ]
            for stage in [PiInstallError.Stage.release, .download] {
                for (status, headers, reason) in cases {
                    let response = try #require(HTTPURLResponse(
                        url: url, statusCode: status, httpVersion: nil, headerFields: headers
                    ))
                    #expect(throws: PiInstallError(stage: stage, reason: reason, httpStatus: status)) {
                        try PiInstaller.validateResponse(response, stage: stage)
                    }
                }
            }
            let ok = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            try PiInstaller.validateResponse(ok, stage: .release)
        }

        @Test
        func releaseFailuresAreReportedOnceWithoutResponseContent() async throws {
            let reports = Mutex<[PiInstallError]>([])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let origin = "https://registry.example"
            defer { ImageURLProtocol.remove(origin: origin) }
            for (status, headers, reason) in [
                (403, ["X-RateLimit-Remaining": "0"], PiInstallError.Reason.rateLimited),
                (200, [:], .invalidRelease),
            ] {
                reports.withLock { $0.removeAll() }
                ImageURLProtocol.register(origin: origin) { _ in
                    (status, headers, Data("private response body".utf8))
                }
                do {
                    _ = try await PiInstaller.release(
                        session: session, registry: origin, reportFailure: { failure in reports.withLock { $0.append(failure) } }
                    )
                    Issue.record("Expected release failure")
                } catch let failure as PiInstallError {
                    #expect(failure.stage == .release)
                    #expect(failure.reason == reason)
                    #expect(failure.httpStatus == (status == 200 ? nil : status))
                    #expect(reports.withLock { $0 } == [failure])
                    #expect(!failure.localizedDescription.contains("private"))
                }
            }
        }

        @Test
        func latestReleaseIsTheOneTheRegistryServes() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let origin = "https://registry.example"
            defer { ImageURLProtocol.remove(origin: origin) }
            let requested = Mutex<[String]>([])
            ImageURLProtocol.register(origin: origin) { request in
                requested.withLock { $0.append(request.url?.path ?? "") }
                return (200, [:], Data(#"{"name":"@earendil-works/pi-coding-agent","dist-tags":{"latest":"1.5.2"}}"#.utf8))
            }
            // A proxy registry may hold back a release pi.dev already announces; Pi installs what the registry serves.
            let release = try await PiInstaller.release(session: session, registry: "\(origin)/npm/")
            #expect(release.version == "1.5.2")
            #expect(requested.withLock { $0 } == ["/npm/@earendil-works/pi-coding-agent"])
            #expect(try await PiInstaller.release(version: "v1.4.0", session: session, registry: origin).version == "1.4.0")
        }

        @Test
        func updateInstallsTheRegistrysLatestReleaseWithBunGlobally() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiInstallerUpdateTests-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appending(path: "bun")
            let package = directory.appending(path: "install/global/node_modules/@earendil-works/pi-coding-agent")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory.appending(path: "bin"), withIntermediateDirectories: true)
            try Data(#"{"version":"1.5.1"}"#.utf8).write(to: package.appending(path: "package.json"))
            // A stand-in for Bun: `install -g` records its arguments and installs the version its last argument names.
            for (name, script) in [("bin/pi", "#!/bin/sh\n"), ("bin/bun", #"""
            #!/bin/sh
            echo "$@" > "$BUN_INSTALL/args"
            for spec; do :; done
            echo "{\"version\":\"${spec##*@}\"}" > "$BUN_INSTALL/install/global/node_modules/@earendil-works/pi-coding-agent/package.json"
            """#)] {
                try Data(script.utf8).write(to: directory.appending(path: name))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appending(path: name).path)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let origin = "https://registry.example"
            defer { ImageURLProtocol.remove(origin: origin) }
            let latest = Mutex("1.5.2")
            ImageURLProtocol.register(origin: origin) { _ in
                (200, [:], Data(#"{"dist-tags":{"latest":"\#(latest.withLock { $0 })"}}"#.utf8))
            }
            func update() async throws -> String {
                try await PiInstaller.update(
                    in: directory, session: session, environment: ProcessInfo.processInfo.environment, registry: origin,
                    reportFailure: { _ in }
                )
            }

            // Unlike `pi update`, which asks pi.dev, the version is the one the registry (often a proxy) serves.
            #expect(try await update() == "1.5.2")
            let args = directory.appending(path: "args")
            #expect(try String(contentsOf: args, encoding: .utf8)
                == "install -g --ignore-scripts --minimum-release-age=0 --no-progress @earendil-works/pi-coding-agent@1.5.2\n")
            #expect(try String(contentsOf: directory.appending(path: "install/global/.npmrc"), encoding: .utf8) == "registry=\(origin)\n")

            // A registry at or behind the installed version runs nothing and does not downgrade.
            try FileManager.default.removeItem(at: args)
            for version in ["1.5.2", "1.4.10"] {
                try Data("registry=https://previous.example\n".utf8).write(to: directory.appending(path: "install/global/.npmrc"))
                latest.withLock { $0 = version }
                #expect(try await update() == "1.5.2")
                #expect(try String(contentsOf: directory.appending(path: "install/global/.npmrc"), encoding: .utf8) == "registry=\(origin)\n")
            }
            #expect(!FileManager.default.fileExists(atPath: args.path))
        }

        @Test
        func cancelledPackageInstallStopsItsChildAndDoesNotActivate() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiCancelledInstall-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bun = root.appending(path: "fake-bun")
            try Data(#"""
            #!/bin/sh
            trap 'echo stopped > "$BUN_INSTALL/stopped"; exit 143' TERM
            mkfifo "$BUN_INSTALL/wait"
            exec 3<>"$BUN_INSTALL/wait"
            echo started > "$BUN_INSTALL/started"
            read -r line <&3
            """#.utf8).write(to: bun)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bun.path)
            let task = Task {
                try await PiInstaller.withCancellableProcess { process in
                    try PiInstaller.install(
                        version: "1.0.0", packageJSON: Data("{}".utf8), packageLock: Data(#"{"packages":{}}"#.utf8),
                        npmrc: Data(), bun: bun, environment: ProcessInfo.processInfo.environment, into: root, process: process
                    )
                }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: root.appending(path: "started").path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let started = FileManager.default.fileExists(atPath: root.appending(path: "started").path)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(started)
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "stopped").path))
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "install/global").path))
            #expect(PiInstaller.installedVersion(in: root) == nil)
        }

        @Test
        func networkErrorsAreCategorizedAndCancellationIsNotReported() {
            for (code, reason) in [
                (URLError.Code.timedOut, PiInstallError.Reason.networkTimeout),
                (.notConnectedToInternet, .networkOffline), (.serverCertificateUntrusted, .networkTLS),
                (.cannotFindHost, .networkOther),
            ] {
                var reports: [PiInstallError] = []
                let error = URLError(code, userInfo: [NSLocalizedDescriptionKey: "private URL and path"])
                let failure = PiInstaller.reportedFailure(error, stage: .download) { reports.append($0) } as? PiInstallError
                #expect(failure == PiInstallError(stage: .download, reason: reason))
                #expect(reports == [failure].compactMap(\.self))
                #expect(failure?.localizedDescription.contains("private") == false)
            }
            for error in [CancellationError(), URLError(.cancelled)] as [Error] {
                _ = PiInstaller.reportedFailure(error, stage: .download) { _ in Issue.record("Cancellation must not be reported") }
            }
        }

        @Test
        func cancelledTaskDoesNotReportWrappedInstallationFailures() async {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                for stage in [PiInstallError.Stage.release, .verification, .extraction, .download, .activation] {
                    let error = PiInstallError(stage: stage, reason: .extractionFailed)
                    let result = PiInstaller.reportedFailure(error, stage: stage) { _ in
                        Issue.record("A cancelled task must not report an installation failure")
                    }
                    #expect(result is CancellationError)
                }
            }
            await task.value
        }

        @Test
        func downloadFileErrorsUseStorageGuidanceAndSanitizedReporting() {
            let codes: [URLError.Code] = [
                .cannotCreateFile, .cannotOpenFile, .cannotCloseFile, .cannotWriteToFile,
                .cannotRemoveFile, .cannotMoveFile,
            ]
            for code in codes {
                var reports: [PiInstallError] = []
                let error = URLError(code, userInfo: [NSLocalizedDescriptionKey: "private archive path"])
                let failure = PiInstaller.reportedFailure(error, stage: .download) { reports.append($0) } as? PiInstallError
                let expected = PiInstallError(stage: .download, reason: .fileSystem)
                #expect(failure == expected)
                #expect(failure?.localizedDescription == L10n.piInstallFailed(
                    L10n.piInstallDownloadStage, L10n.piInstallFileSystemFailed
                ))
                #expect(reports == [expected])
                #expect(reports.map(\.diagnosticContext) == [[
                    "source": "piInstallation", "piInstallStage": "download", "piInstallReason": "fileSystem",
                ]])
            }
        }

        @Test
        func fileSystemFailuresAreReportedAtActivation() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiBlockedFolder-\(UUID())")
            try Data().write(to: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let reports = Mutex<[PiInstallError]>([])
            do {
                try await PiInstaller.install(
                    PiInstaller.Release(version: "1.0.0"), into: root.appending(path: "Pi"),
                    reportFailure: { failure in reports.withLock { $0.append(failure) } }
                )
                Issue.record("A file cannot contain an installation folder")
            } catch let failure as PiInstallError {
                #expect(failure == PiInstallError(stage: .activation, reason: .fileSystem))
                #expect(reports.withLock { $0 } == [failure])
            }
        }

        @Test
        func bunArchiveFailuresKeepTheirStageAndLeaveNoBun() async throws {
            try await Task.detached {
                let root = FileManager.default.temporaryDirectory.appending(path: "PiBadArchive-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                func digest(_ url: URL) throws -> String {
                    try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                }
                let bun = root.appending(path: "bun/bin/bun")
                let broken = root.appending(path: "bad.zip")
                try Data("not an archive".utf8).write(to: broken)
                #expect(throws: PiInstallError(stage: .verification, reason: .checksumMismatch)) {
                    try PiInstaller.installBun(archive: broken, sha256: "wrong", to: bun)
                }
                #expect(throws: PiInstallError(stage: .extraction, reason: .extractionFailed)) {
                    try PiInstaller.installBun(archive: broken, sha256: digest(broken), to: bun)
                }
                /// A valid archive without Bun must differ from a broken one.
                func zip(_ name: String, executable: Bool) throws -> URL {
                    let source = root.appending(path: "source-\(name)/bun-darwin-aarch64")
                    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                    if executable {
                        try Data("#!/bin/sh\n".utf8).write(to: source.appending(path: "bun"))
                        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appending(path: "bun").path)
                    }
                    let url = root.appending(path: "\(name).zip")
                    let ditto = Process()
                    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    ditto.arguments = ["-c", "-k", "--keepParent", source.path, url.path]
                    try ditto.run()
                    ditto.waitUntilExit()
                    #expect(ditto.terminationStatus == 0)
                    return url
                }
                let empty = try zip("empty", executable: false)
                #expect(throws: PiInstallError(stage: .extraction, reason: .executableMissing)) {
                    try PiInstaller.installBun(archive: empty, sha256: digest(empty), to: bun)
                }
                #expect(!FileManager.default.fileExists(atPath: bun.path))
                let valid = try zip("valid", executable: true)
                try PiInstaller.installBun(archive: valid, sha256: digest(valid).uppercased(), to: bun)
                #expect(CommandLineToolLocator.isExecutableFile(atPath: bun.path))
                #expect(try FileManager.default.contentsOfDirectory(atPath: bun.deletingLastPathComponent().path) == ["bun"])
            }.value
        }
    }
#endif

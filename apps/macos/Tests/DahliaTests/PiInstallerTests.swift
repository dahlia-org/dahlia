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
            let origin = "https://api.github.com"
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
                    _ = try await PiInstaller.release(session: session, reportFailure: { failure in reports.withLock { $0.append(failure) } })
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
        func missingAssetAndDigestAreReportedWithoutDownloading() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiInstallerErrors-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let reports = Mutex<[PiInstallError]>([])
            for (assets, reason) in try [
                ([], PiInstallError.Reason.missingAsset),
                (
                    [PiInstaller.Release.Asset(
                        name: "pi-darwin-arm64.tar.gz",
                        url: #require(URL(string: "https://example.test/asset")),
                        digest: nil
                    )],
                    .missingDigest
                ),
            ] {
                reports.withLock { $0.removeAll() }
                do {
                    try await PiInstaller.install(
                        PiInstaller.Release(tagName: "v1.0.0", assets: assets), into: root.appending(path: "Pi"),
                        reportFailure: { failure in reports.withLock { $0.append(failure) } }
                    )
                    Issue.record("Expected metadata failure")
                } catch let failure as PiInstallError {
                    #expect(failure == PiInstallError(stage: .release, reason: reason))
                    #expect(reports.withLock { $0 } == [failure])
                }
            }
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
        func fileSystemFailuresAreReportedAtActivation() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiBlockedFolder-\(UUID())")
            try Data().write(to: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let reports = Mutex<[PiInstallError]>([])
            do {
                try await PiInstaller.install(
                    PiInstaller.Release(tagName: "v1.0.0", assets: []), into: root.appending(path: "Pi"),
                    reportFailure: { failure in reports.withLock { $0.append(failure) } }
                )
                Issue.record("A file cannot contain an installation folder")
            } catch let failure as PiInstallError {
                #expect(failure == PiInstallError(stage: .activation, reason: .fileSystem))
                #expect(reports.withLock { $0 } == [failure])
            }
        }

        @Test
        func archiveFailuresKeepTheirStageAndLeaveNoPartialInstallation() async throws {
            try await Task.detached {
                let root = FileManager.default.temporaryDirectory.appending(path: "PiBadArchive-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let archive = root.appending(path: "bad.tar.gz")
                let bytes = Data("not an archive".utf8)
                try bytes.write(to: archive)
                let directory = root.appending(path: "Pi")
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                #expect(throws: PiInstallError(stage: .verification, reason: .checksumMismatch)) {
                    try PiInstaller.install(archive: archive, sha256: "wrong", version: "1.0.0", into: directory)
                }
                #expect(throws: PiInstallError(stage: .extraction, reason: .extractionFailed)) {
                    try PiInstaller.install(archive: archive, sha256: digest, version: "1.0.0", into: directory)
                }
                // A valid archive without pi must differ from a broken gzip file.
                let emptyArchive = root.appending(path: "empty.tar.gz")
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["-czf", emptyArchive.path, "-T", "/dev/null"]
                try tar.run()
                tar.waitUntilExit()
                #expect(tar.terminationStatus == 0)
                let emptyDigest = try SHA256.hash(data: Data(contentsOf: emptyArchive)).map { String(format: "%02x", $0) }.joined()
                #expect(throws: PiInstallError(stage: .extraction, reason: .executableMissing)) {
                    try PiInstaller.install(archive: emptyArchive, sha256: emptyDigest, version: "1.0.0", into: directory)
                }
                #expect(PiInstaller.installedVersion(in: directory) == nil)
                #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            }.value
        }
    }
#endif

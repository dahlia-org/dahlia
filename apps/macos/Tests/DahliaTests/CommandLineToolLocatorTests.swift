import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CommandLineToolLocatorTests {
        @Test(arguments: [".local/bin", ".bun/bin", "bin", "Library/pnpm", ".volta/bin", ".npm-global/bin"])
        func discoversCommonUserInstallLocations(relativePath: String) async throws {
            try await Task.detached {
                try Self.withTemporaryHome { home in
                    let name = "pi-\(UUID())"
                    let executable = home.appending(path: relativePath).appending(path: name)
                    try Self.writeExecutable(at: executable)
                    let environment = ["PATH": "/usr/bin:/bin"]
                    #expect(CommandLineToolLocator.executableURL(
                        named: name, environment: environment, homeDirectory: home
                    ) == executable)
                    let path = CommandLineToolLocator.searchPath(
                        for: executable, environment: environment, homeDirectory: home
                    ).split(separator: ":").map(String.init)
                    #expect(path.contains("/opt/homebrew/bin"))
                    #expect(path.contains("/opt/homebrew/sbin"))
                    #expect(path.contains("/usr/local/bin"))
                    #expect(path.contains("/usr/local/sbin"))
                    #expect(path.contains("/opt/homebrew/opt/libpq/bin"))
                    #expect(Set(path).count == path.count)
                }
            }.value
        }

        @Test
        func nvmFindsPiAcrossVersionsAndRunsItsMatchingNode() async throws {
            try await Task.detached {
                try Self.withTemporaryHome { home in
                    let name = "pi-\(UUID())"
                    let versions = home.appending(path: ".nvm/versions/node")
                    for version in ["v24.9.0", "v24.22.1", "v25.1.0", "vnot-a-version"] {
                        let bin = versions.appending(path: "\(version)/bin")
                        try Self.writeExecutable(at: bin.appending(path: "node"), script: "#!/bin/sh\nprintf '%s' '\(version)'\n")
                        if version != "v25.1.0" {
                            try Self.writeExecutable(at: bin.appending(path: name), script: "#!/usr/bin/env node\n")
                        }
                    }
                    let environment = ["PATH": "/usr/bin:/bin"]
                    let pi = try #require(CommandLineToolLocator.executableURL(
                        named: name, environment: environment, homeDirectory: home
                    ))
                    #expect(pi == versions.appending(path: "v24.22.1/bin/\(name)"))
                    let path = CommandLineToolLocator.searchPath(for: pi, environment: environment, homeDirectory: home)
                    #expect(path.hasPrefix("\(pi.deletingLastPathComponent().path):"))
                    let process = Process()
                    let output = Pipe()
                    process.executableURL = pi
                    process.environment = ["PATH": path]
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    process.standardInput = FileHandle.nullDevice
                    try process.run()
                    let result = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    #expect(process.terminationStatus == 0)
                    #expect(String(decoding: result, as: UTF8.self) == "v24.22.1")

                    let selectedBin = versions.appending(path: "v24.9.0/bin")
                    #expect(CommandLineToolLocator.executableURL(
                        named: name, environment: ["PATH": "\(selectedBin.path):/usr/bin:/bin"], homeDirectory: home
                    ) == selectedBin.appending(path: name))
                }
            }.value
        }

        @Test(arguments: [true, false])
        func respectsCustomNvmDirectory(expandTilde: Bool) async throws {
            try await Task.detached {
                try Self.withTemporaryHome { home in
                    let name = "pi-\(UUID())"
                    let custom = home.appending(path: "custom nvm")
                    let executable = custom.appending(path: "versions/node/v24.22.1/bin/\(name)")
                    try Self.writeExecutable(at: executable)
                    try Self.writeExecutable(at: home.appending(path: ".nvm/versions/node/v99.0.0/bin/\(name)"))
                    #expect(CommandLineToolLocator.executableURL(
                        named: name,
                        environment: ["PATH": "/usr/bin:/bin", "NVM_DIR": expandTilde ? "~/custom nvm" : custom.path],
                        homeDirectory: home
                    ) == executable)
                }
            }.value
        }

        @Test
        func discoversNvmInstalledAfterAnEarlierLookup() async throws {
            try await Task.detached {
                try Self.withTemporaryHome { home in
                    let name = "pi-\(UUID())"
                    #expect(CommandLineToolLocator.executableURL(named: name, environment: [:], homeDirectory: home) == nil)
                    let pi = home.appending(path: ".nvm/versions/node/v24.22.1/bin/\(name)")
                    try Self.writeExecutable(at: pi)
                    #expect(CommandLineToolLocator.executableURL(named: name, environment: [:], homeDirectory: home) == pi)
                }
            }.value
        }

        private static func withTemporaryHome(_ body: (URL) throws -> Void) throws {
            let home = FileManager.default.temporaryDirectory.appending(path: "tool-locator-\(UUID())")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            try body(home)
        }

        private static func writeExecutable(at url: URL, script: String = "#!/bin/sh\n") throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
#endif

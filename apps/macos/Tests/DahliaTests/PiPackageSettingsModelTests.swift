import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct PiPackageSettingsModelTests {
        @Test(arguments: [true, false], [true, false])
        func commandOutcomeIsIndependentOfRefreshFailure(commandFails: Bool, refreshFails: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiPackageModel-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let locator = PiAgentDirectoryLocator(applicationSupportURL: root)
            let settings = try locator.agentURL().appending(path: "settings.json")
            try Data((refreshFails ? "invalid JSON" : #"{"packages":["npm:tools"]}"#).utf8).write(to: settings)
            let detail = "npm error code ENOVERSIONS\nNo versions available"
            let model = PiPackageSettingsModel(service: PiPackageService(locator: locator), changePackage: { _, _ in
                if commandFails { throw PiPackageService.PackageError.commandFailed(detail) }
            })
            model.source = "npm:tools"
            model.install()
            #expect(model.isBusy)
            #expect(!model.changeSucceeded)
            #expect(await pollUntil { !model.isBusy })
            #expect(model.changeSucceeded == !commandFails)
            #expect(model.source == (commandFails ? "npm:tools" : ""))
            #expect(model.didChange == !commandFails)
            if commandFails {
                #expect(model.errorMessage == PiPackageService.PackageError.commandFailed(detail).localizedDescription)
                #expect(model.errorDetails == detail)
            } else {
                #expect((model.errorMessage != nil) == refreshFails)
                #expect(model.errorDetails == nil)
            }
        }

        @Test
        func outcomeResetsOnRetryAndRemoval() async {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiPackageModel-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let locator = PiAgentDirectoryLocator(applicationSupportURL: root)
            let model = PiPackageSettingsModel(service: PiPackageService(locator: locator), changePackage: { source, _ in
                if source == "npm:fail" { throw PiPackageService.PackageError.commandFailed("failed") }
            })

            for source in ["npm:tools", "npm:fail", "npm:tools"] {
                model.source = source
                model.install()
                #expect(!model.changeSucceeded)
                #expect(await pollUntil { !model.isBusy })
                #expect(model.changeSucceeded == (source != "npm:fail"))
                #expect((model.errorMessage == nil) == (source != "npm:fail"))
            }
            model.remove("npm:tools")
            #expect(!model.changeSucceeded)
            #expect(await pollUntil { !model.isBusy })
            #expect(model.changeSucceeded)
        }

        @Test(arguments: [true, false])
        func standaloneRefreshReplacesEarlierErrors(commandFails: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiPackageModel-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let locator = PiAgentDirectoryLocator(applicationSupportURL: root)
            let settings = try locator.agentURL().appending(path: "settings.json")
            try Data("invalid JSON".utf8).write(to: settings)
            let service = PiPackageService(locator: locator)
            let model = PiPackageSettingsModel(service: service, changePackage: { _, _ in
                throw PiPackageService.PackageError.commandFailed("command output")
            })
            if commandFails {
                model.source = "npm:tools"
                model.install()
                #expect(await pollUntil { !model.isBusy })
                #expect(model.errorDetails == "command output")
            } else {
                await model.refresh()
            }
            let earlierMessage = try #require(model.errorMessage)

            try FileManager.default.removeItem(at: settings)
            try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
            var expectedMessage: String?
            do {
                _ = try await service.packages()
                Issue.record("Expected a directory in place of settings.json to fail")
            } catch {
                expectedMessage = error.localizedDescription
            }
            let newerMessage = try #require(expectedMessage)
            #expect(newerMessage != earlierMessage)
            await model.refresh()
            #expect(model.errorMessage == newerMessage)
            #expect(model.errorDetails == nil)
        }

        @Test(arguments: [true, false], [true, false])
        func overlappingRefreshPreservesCommandFailure(startsBeforeCommand: Bool, finishesBeforeCommand: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiPackageModel-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let reads = PackageReadGate()
            let commands = PackageReadGate()
            let model = PiPackageSettingsModel(
                service: PiPackageService(locator: .init(applicationSupportURL: root)),
                loadPackages: { try await reads.read() },
                changePackage: { _, _ in _ = try await commands.read() }
            )
            var refresh: Task<Void, Never>?
            if startsBeforeCommand {
                refresh = Task { await model.refresh() }
                try #require(await pollUntil { await reads.isWaiting(0) })
            }
            model.source = "npm:tools"
            model.install()
            try #require(await pollUntil { await commands.isWaiting(0) })
            if !startsBeforeCommand {
                refresh = Task { await model.refresh() }
                try #require(await pollUntil { await reads.isWaiting(0) })
            }
            if finishesBeforeCommand {
                await reads.fail(0, error: PackageReadFailure(message: "overlapping refresh"))
                await refresh?.value
            }
            await commands.fail(0, error: PiPackageService.PackageError.commandFailed("command output"))
            try #require(await pollUntil { await reads.isWaiting(1) })
            if !finishesBeforeCommand {
                await reads.fail(0, error: PackageReadFailure(message: "overlapping refresh"))
                await refresh?.value
            }
            #expect(model.errorMessage == PiPackageService.PackageError.commandFailed("command output").localizedDescription)
            #expect(model.errorDetails == "command output")
            await reads.fail(1, error: PackageReadFailure(message: "follow-up refresh"))
            #expect(await pollUntil { !model.isBusy })
            #expect(model.errorDetails == "command output")
        }

        @Test
        func refreshStartedAfterCommandResultCanReplaceErrorWhileFollowUpIsPending() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "PiPackageModel-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let reads = PackageReadGate()
            let model = PiPackageSettingsModel(
                service: PiPackageService(locator: .init(applicationSupportURL: root)),
                loadPackages: { try await reads.read() },
                changePackage: { _, _ in throw PiPackageService.PackageError.commandFailed("command output") }
            )
            model.source = "npm:tools"
            model.install()
            try #require(await pollUntil { await reads.isWaiting(0) })
            #expect(model.isBusy)
            #expect(model.errorDetails == "command output")
            let refresh = Task { await model.refresh() }
            try #require(await pollUntil { await reads.isWaiting(1) })
            await reads.fail(1, error: PackageReadFailure(message: "new refresh"))
            await refresh.value
            #expect(model.errorMessage == "new refresh")
            #expect(model.errorDetails == nil)
            await reads.fail(0, error: PackageReadFailure(message: "follow-up refresh"))
            #expect(await pollUntil { !model.isBusy })
            #expect(model.errorMessage == "new refresh")
            #expect(model.errorDetails == nil)
        }
    }

    private struct PackageReadFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private actor PackageReadGate {
        private var nextID = 0
        private var pending: [Int: CheckedContinuation<[String], any Error>] = [:]

        func read() async throws -> [String] {
            let id = nextID
            nextID += 1
            return try await withCheckedThrowingContinuation { pending[id] = $0 }
        }

        func isWaiting(_ id: Int) -> Bool { pending[id] != nil }

        func fail(_ id: Int, error: any Error) {
            guard let continuation = pending.removeValue(forKey: id) else {
                Issue.record("No pending read for \(id)")
                return
            }
            continuation.resume(throwing: error)
        }
    }
#endif

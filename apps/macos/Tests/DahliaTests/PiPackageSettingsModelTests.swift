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
            let model = PiPackageSettingsModel(service: PiPackageService(locator: locator)) { _, _ in
                if commandFails { throw PiPackageService.PackageError.commandFailed(detail) }
            }
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
            let model = PiPackageSettingsModel(service: PiPackageService(locator: locator)) { source, _ in
                if source == "npm:fail" { throw PiPackageService.PackageError.commandFailed("failed") }
            }

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
            let model = PiPackageSettingsModel(service: service) { _, _ in
                throw PiPackageService.PackageError.commandFailed("command output")
            }
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
    }
#endif

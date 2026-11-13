#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct PiSetupModelTests {
        @Test
        func successfulInstallEnablesOnlyTheSelectedAccount() async throws {
            let suite = "PiSetup-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let account = CodexRuntimeProvider.databricks(connectionID: .v7())
            let model = PiSetupModel(account: account, defaults: defaults)
            var installs = 0

            await model.refresh { false }
            await model.install { installs += 1 }

            #expect(installs == 1)
            #expect(model.isReady)
            #expect(PiBundle.usesManagedPi(for: account, defaults: defaults))
            #expect(!PiBundle.usesManagedPi(for: .local, defaults: defaults))
        }

        @Test
        func existingInstallationIsReusedOnlyAfterConsent() async throws {
            let suite = "PiSetup-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = PiSetupModel(account: .local, defaults: defaults)
            await model.refresh { true }
            #expect(model.hasManagedPi)
            #expect(!model.isReady)
            #expect(!PiBundle.usesManagedPi(for: .local, defaults: defaults))

            await model.install { Issue.record("Existing Pi must not be downloaded again") }

            #expect(model.isReady)
            #expect(PiBundle.usesManagedPi(for: .local, defaults: defaults))
        }

        @Test
        func failedInstallationPreservesSelectionAndCanRetry() async throws {
            let suite = "PiSetup-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let key = PiBundle.useManagedPiDefaultsKey(for: .local)
            defaults.set(false, forKey: key)
            let model = PiSetupModel(account: .local, defaults: defaults)

            let failure = PiInstallError(stage: .download, reason: .http, httpStatus: 403)
            await model.install { throw failure }

            #expect(model.errorMessage == failure.localizedDescription)
            #expect(!model.isReady)
            #expect(!defaults.bool(forKey: key))
            await model.install {}
            #expect(model.errorMessage == nil)
            #expect(model.isReady)
            #expect(defaults.bool(forKey: key))
        }

        @Test
        func cancelledInstallationDoesNotEnableManagedPi() async throws {
            let suite = "PiSetup-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = PiSetupModel(account: .local, defaults: defaults)
            let task = Task {
                await model.install {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            await task.value

            #expect(!model.isReady)
            #expect(model.errorMessage == nil)
            #expect(defaults.object(forKey: PiBundle.useManagedPiDefaultsKey(for: .local)) == nil)
        }
    }
#endif

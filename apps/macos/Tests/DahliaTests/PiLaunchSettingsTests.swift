import Foundation
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct PiLaunchSettingsTests {
        private static let account = CodexRuntimeProvider.databricks(connectionID: UUID())

        /// Secrets kept in memory instead of the Keychain.
        private final class MemorySecrets: Sendable {
            let values = Mutex<[String: String]>([:])

            var secrets: PiLaunchSettingsModel.Secrets {
                PiLaunchSettingsModel.Secrets(
                    load: { key in self.values.withLock { $0[key] } },
                    save: { key, value in self.values.withLock { $0[key] = value } },
                    delete: { key in _ = self.values.withLock { $0.removeValue(forKey: key) } }
                )
            }
        }

        @Test
        func variablesWithAValidNameAndAValueReachPi() {
            let secretID = UUID()
            let settings = PiLaunchSettings(variables: [
                .init(id: UUID(), name: "OPENAI_BASE_URL", value: "https://example.com"),
                .init(id: secretID, name: "OPENAI_API_KEY", isSecret: true),
                .init(id: UUID(), name: "1INVALID", value: "x"),
                .init(id: UUID(), name: "", value: "x"),
                .init(id: UUID(), name: "MISSING_SECRET", isSecret: true),
                // A row just added, named before its value is typed, must not blank an inherited variable.
                .init(id: UUID(), name: "HOME", value: ""),
            ])

            #expect(settings.environment { $0 == secretID ? "sk-test" : nil } == [
                "OPENAI_BASE_URL": "https://example.com",
                "OPENAI_API_KEY": "sk-test",
            ])
        }

        @Test
        func secretsLiveOnlyInTheKeychainAndAreNeverReadBack() async throws {
            let defaults = try #require(UserDefaults(suiteName: "PiLaunchSettingsTests.\(UUID())"))
            let memory = MemorySecrets()
            let model = PiLaunchSettingsModel(account: Self.account, defaults: defaults, secrets: memory.secrets)

            model.addVariable()
            let id = try #require(model.settings.variables.first?.id)
            model.setName("API_KEY", of: id)
            model.setValue("plain", of: id)
            #expect(PiLaunchSettings.load(for: Self.account, defaults: defaults) == model.settings)

            // Making it secret moves the value to the Keychain and out of app defaults.
            try await model.setSecret(true, of: id)
            let key = PiLaunchSettings.secretKey(for: Self.account, id: id)
            #expect(memory.values.withLock { $0 } == [key: "plain"])
            #expect(PiLaunchSettings.load(for: Self.account, defaults: defaults).variables.first?.value == nil)
            #expect(model.storedSecretIDs == [id])
            try await model.setSecretValue("replaced", of: id)
            #expect(memory.values.withLock { $0[key] } == "replaced")

            // A new model sees that a secret is stored without reading it.
            let reopened = PiLaunchSettingsModel(account: Self.account, defaults: defaults, secrets: memory.secrets)
            await reopened.refreshStoredSecrets()
            #expect(reopened.storedSecretIDs == [id])
            let environment = reopened.settings.environment { id in
                memory.values.withLock { $0[PiLaunchSettings.secretKey(for: Self.account, id: id)] }
            }
            #expect(environment == ["API_KEY": "replaced"])

            // Making it plain again clears the value; removing a variable deletes its secret.
            try await model.setSecret(false, of: id)
            #expect(memory.values.withLock { $0 }.isEmpty)
            #expect(model.settings.variables.first?.value?.isEmpty == true)
            try await model.setSecret(true, of: id)
            try await model.setSecretValue("again", of: id)
            await model.removeVariable(id)
            #expect(memory.values.withLock { $0 }.isEmpty)
            #expect(PiLaunchSettings.load(for: Self.account, defaults: defaults) == PiLaunchSettings())
        }

        @Test(arguments: ["PATH", "NVM_DIR"])
        func discoveryRevisionTracksRelevantEditsAndSecretReplacements(name: String) async throws {
            let suite = "PiLaunchSettingsTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let memory = MemorySecrets()
            let model = PiLaunchSettingsModel(account: Self.account, defaults: defaults, secrets: memory.secrets)
            model.addVariable()
            let id = try #require(model.settings.variables.first?.id)
            model.setName("OTHER_VARIABLE", of: id)
            model.setValue("unrelated", of: id)
            #expect(model.commandDiscoveryRevision == 0)
            model.setName(name, of: id)
            #expect(model.commandDiscoveryRevision == 1)
            model.setValue("/first", of: id)
            #expect(model.commandDiscoveryRevision == 2)
            try await model.setSecret(true, of: id)
            #expect(model.commandDiscoveryRevision == 3)
            try await model.setSecretValue("/replacement", of: id)
            #expect(model.commandDiscoveryRevision == 4)
            #expect(model.settings.variables.first?.value == nil)
            model.setName("OTHER_VARIABLE", of: id)
            #expect(model.commandDiscoveryRevision == 5)
            try await model.setSecretValue("unrelated replacement", of: id)
            #expect(model.commandDiscoveryRevision == 5)
            model.setName(name, of: id)
            #expect(model.commandDiscoveryRevision == 6)
            await model.removeVariable(id)
            #expect(model.commandDiscoveryRevision == 7)
        }
    }
#endif

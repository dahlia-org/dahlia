#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct GeneralSettingsViewTests {
        @Test
        func languageSelectionDraftCommitsOnlyWhenRequested() {
            var savedScope: AppLanguageScope?
            var savedIdentifiers: Set<String>?
            var draft = AppLanguageSelectionDraft(
                scope: .selected,
                enabledLanguageIdentifiers: ["en", "ja"]
            )

            draft.scope = .all
            draft.enabledLanguageIdentifiers = ["fr"]

            #expect(savedScope == nil)
            #expect(savedIdentifiers == nil)

            draft.commit { scope, identifiers in
                savedScope = scope
                savedIdentifiers = identifiers
            }

            #expect(savedScope == .all)
            #expect(savedIdentifiers == ["fr"])
        }

        @Test
        func languageSelectionSummaryIsBounded() {
            let summary = AppLanguageSelectionRow.summaryParts(
                identifiers: ["en", "fr", "ja"],
                locale: Locale(identifier: "en")
            )
            let emptySummary = AppLanguageSelectionRow.summaryParts(
                identifiers: [],
                locale: Locale(identifier: "en")
            )

            #expect(summary.names == ["English", "French"])
            #expect(summary.remainingCount == 1)
            #expect(emptySummary.names.isEmpty)
            #expect(emptySummary.remainingCount == 0)
        }

        @Test
        func selectedLanguageDraftRejectsAnEmptySelection() {
            var didSave = false
            let draft = AppLanguageSelectionDraft(
                scope: .selected,
                enabledLanguageIdentifiers: []
            )

            draft.commit { _, _ in didSave = true }

            #expect(!draft.isValid)
            #expect(!didSave)
            #expect(AppLanguageSelectionDraft(scope: .all, enabledLanguageIdentifiers: []).isValid)
        }

        @Test
        func dahliaCloudAccountStatesCoverDisabledDisconnectedAndConnected() async throws {
            let disabledService = DahliaCloudService(
                configuration: nil,
                storage: DahliaCloudCredentialStorage(load: { nil }, save: { _ in }, delete: {})
            )
            let disabled = DahliaCloudAccountController(configuration: nil, service: disabledService)
            await disabled.activate()
            #expect(disabled.defaultConfiguration == nil)
            #expect(disabled.account == nil)

            let configuration = try #require(DahliaCloudConfiguration.make(
                urlString: "https://cloud.example.com",
                clientID: "desktop-client"
            ))
            let disconnectedService = DahliaCloudService(
                configuration: configuration,
                storage: DahliaCloudCredentialStorage(load: { nil }, save: { _ in }, delete: {})
            )
            let disconnected = DahliaCloudAccountController(configuration: configuration, service: disconnectedService)
            await disconnected.activate()
            #expect(disconnected.defaultConfiguration == configuration)
            #expect(disconnected.account == nil)
            #expect(!disconnected.isBusy)

            let account = DahliaCloudAccount(id: "user", name: "User", email: "user@example.com")
            let credential = DahliaCloudCredential(
                accessToken: "access",
                refreshToken: "refresh",
                expirationDate: .distantFuture,
                resource: "https://cloud.example.com",
                issuer: "https://accounts.example.com",
                clientID: "desktop-client",
                grantedScopes: ["openid"],
                tokenEndpoint: URL(string: "https://accounts.example.com/token")!,
                revocationEndpoint: nil,
                account: account
            )
            let connectedService = DahliaCloudService(
                configuration: configuration,
                storage: DahliaCloudCredentialStorage(load: { credential }, save: { _ in }, delete: {})
            )
            let connected = DahliaCloudAccountController(configuration: configuration, service: connectedService)
            await connected.activate()
            #expect(connected.account == account)
            #expect(connected.connectionOrigin == "https://cloud.example.com")
            #expect(!connected.isBusy)
            #expect(connected.errorMessage == nil)
        }

        @Test
        func dahliaConnectionPresentationDistinguishesCloudAndServer() async throws {
            let cloudConfiguration = try #require(DahliaCloudConfiguration.make(
                urlString: "https://cloud.example.com",
                clientID: "desktop-client"
            ))
            let account = DahliaCloudAccount(id: "user", name: "Kazuki Matsuda", email: nil)

            func controller(resource: String) async -> DahliaCloudAccountController {
                let credential = DahliaCloudCredential(
                    accessToken: "access",
                    refreshToken: "refresh",
                    expirationDate: .distantFuture,
                    resource: resource,
                    issuer: "https://accounts.example.com",
                    clientID: "desktop-client",
                    grantedScopes: ["openid"],
                    tokenEndpoint: URL(string: "https://accounts.example.com/token")!,
                    revocationEndpoint: nil,
                    account: account
                )
                let service = DahliaCloudService(
                    configuration: cloudConfiguration,
                    storage: DahliaCloudCredentialStorage(load: { credential }, save: { _ in }, delete: {})
                )
                let controller = DahliaCloudAccountController(configuration: cloudConfiguration, service: service)
                await controller.activate()
                return controller
            }

            let cloud = await controller(resource: "https://cloud.example.com/")
            #expect(cloud.connectionStatus == "Dahlia Cloud - Kazuki Matsuda")
            #expect(cloud.connectionDetail == nil)
            #expect(cloud.connectionServiceName == "Dahlia Cloud")
            #expect(cloud.connectionSystemImage == "icloud")

            let server = await controller(resource: "https://server.example.com/api")
            #expect(server.connectionStatus == "Dahlia Server - Kazuki Matsuda")
            #expect(server.connectionDetail == "(https://server.example.com)")
            #expect(server.connectionServiceName == "Dahlia Server")
            #expect(server.connectionSystemImage == "xserve")
        }

        @Test
        func dahliaAccountStatusCopyIsNotCloudSpecific() {
            #expect(!L10n.dahliaNotSignedIn.localizedCaseInsensitiveContains("cloud"))
            #expect(!L10n.dahliaSignedInAs("User").localizedCaseInsensitiveContains("cloud"))
        }

        @Test
        func dahliaCloudActionShowsComingSoonOnlyWhenUnconfigured() {
            #expect(DahliaServerSignInView.cloudActionTitle(isConfigured: true) == L10n.signInToDahliaCloud)
            #expect(DahliaServerSignInView.cloudActionTitle(isConfigured: false) == L10n.dahliaCloudComingSoon)
        }
    }
#endif

import DahliaRuntimeSupport
import Foundation
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexAccountControllerTests {
        /// Sign-in emits Pi's authorization URL and then succeeds; afterwards the provider lists one model.
        private static func runtime(provider: String, signedIn: OSAllocatedUnfairLock<Bool>) -> TestPiRuntime {
            TestPiRuntime { _ in
                TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    switch command["type"]?.stringValue {
                    case "get_available_models":
                        let models = signedIn.withLock { $0 } ? [TestPiTransport.model(provider: provider, id: "model")] : []
                        return [TestPiTransport.response(id: id, data: .object(["models": .array(models)]))]
                    case "prompt":
                        let message = command["message"]?.stringValue ?? ""
                        if message.hasPrefix("/dahlia-login") {
                            signedIn.withLock { $0 = true }
                            return [
                                TestPiTransport.notify("dahlia:auth_url https://auth.example.com/\(provider)"),
                                TestPiTransport.notify("dahlia:login_succeeded"),
                            ]
                        }
                        signedIn.withLock { $0 = false }
                        return [TestPiTransport.response(id: id, data: .object(["disposition": .string("handled")]))]
                    default:
                        return [TestPiTransport.response(id: id)]
                    }
                }
            }
        }

        @Test(arguments: PiSubscription.allCases)
        func explicitSignInOpensBrowserAndRefreshesAccount(subscription: PiSubscription) async throws {
            let piProvider = subscription.rawValue
            let signedIn = OSAllocatedUnfairLock(initialState: false)
            let pi = Self.runtime(provider: piProvider, signedIn: signedIn)
            let urlOpener = TestCodexLoginURLOpener()
            let controller = CodexAccountController(subscription: subscription, service: pi.service, urlOpener: urlOpener)

            await controller.activate()
            #expect(controller.accountStatus?.isAuthenticated == false)
            await controller.signIn()

            #expect(urlOpener.openedURLs == [URL(string: "https://auth.example.com/\(piProvider)")])
            #expect(controller.accountStatus?.isAuthenticated == true)
            #expect(controller.errorMessage == nil)
            let login = try #require(pi.launches.all.first { $0.environment["DAHLIA_PI_DEVICE_ID"] != nil })
            #expect(login.mode == .control)
        }

        @Test
        func browserOpenFailureStopsSignInAndShowsRetryableError() async {
            let pi = Self.runtime(provider: "openai", signedIn: OSAllocatedUnfairLock(initialState: false))
            let controller = CodexAccountController(subscription: .openai, service: pi.service, urlOpener: TestCodexLoginURLOpener(result: false))

            await controller.signIn()

            #expect(controller.errorMessage == L10n.codexLoginPageCouldNotOpen)
            #expect(!controller.isBusy)
        }

        @Test
        func signOutRefreshesTheAccount() async {
            let signedIn = OSAllocatedUnfairLock(initialState: true)
            let pi = Self.runtime(provider: "openai", signedIn: signedIn)
            let controller = CodexAccountController(subscription: .openai, service: pi.service, urlOpener: TestCodexLoginURLOpener())

            await controller.activate()
            #expect(controller.accountStatus?.isAuthenticated == true)
            await controller.signOut()

            #expect(controller.accountStatus?.isAuthenticated == false)
            #expect(controller.errorMessage == nil)
        }

        @Test
        func eachSubscriptionReportsOnlyItsOwnModels() async {
            let pi = Self.runtime(provider: "anthropic", signedIn: OSAllocatedUnfairLock(initialState: true))
            let openAI = CodexAccountController(subscription: .openai, service: pi.service, urlOpener: TestCodexLoginURLOpener())
            let anthropic = CodexAccountController(subscription: .anthropic, service: pi.service, urlOpener: TestCodexLoginURLOpener())

            await openAI.activate()
            await anthropic.activate()

            #expect(openAI.accountStatus?.isAuthenticated == false)
            #expect(anthropic.accountStatus?.isAuthenticated == true)
        }
    }
#endif

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

        /// Once Pi has saved the credential, the sign-in leaves its waiting-for-browser phase, and a cancel from then on
        /// still lets the new status arrive, so the saved sign-in never shows as signed out.
        @Test
        func cancelAfterTheBrowserStepKeepsTheSavedSignIn() async throws {
            let signedIn = OSAllocatedUnfairLock(initialState: false)
            let heldStatusRequest = OSAllocatedUnfairLock<JSONValue?>(initialState: nil)
            let transports = TestPiTransportLog()
            let pi = TestPiRuntime { _ in
                let transport = TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    switch command["type"]?.stringValue {
                    case "get_available_models":
                        // Hold the first listing after the browser step until the test has observed that phase.
                        let holds = signedIn.withLock { $0 } && heldStatusRequest.withLock { held in
                            guard held == nil else { return false }
                            held = id
                            return true
                        }
                        let models = signedIn.withLock { $0 } ? [TestPiTransport.model(provider: "openai", id: "model")] : []
                        return holds ? [] : [TestPiTransport.response(id: id, data: .object(["models": .array(models)]))]
                    case "prompt":
                        signedIn.withLock { $0 = true }
                        return [
                            TestPiTransport.notify("dahlia:auth_url https://auth.example.com/openai"),
                            TestPiTransport.notify("dahlia:login_succeeded"),
                        ]
                    default:
                        return [TestPiTransport.response(id: id)]
                    }
                }
                transports.append(transport)
                return transport
            }
            let controller = CodexAccountController(subscription: .openai, service: pi.service, urlOpener: TestCodexLoginURLOpener())
            let signIn = Task { await controller.signIn() }

            let deadline = ContinuousClock.now + .seconds(10)
            while heldStatusRequest.withLock({ $0 }) == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let heldID = try #require(heldStatusRequest.withLock { $0 })
            #expect(!controller.isSigningIn)
            #expect(controller.isCheckingStatus)
            signIn.cancel()

            let models = JSONValue.object(["models": .array([TestPiTransport.model(provider: "openai", id: "model")])])
            for transport in transports.all where await transport.commands.contains(where: { $0["id"] == heldID }) {
                await transport.emit(TestPiTransport.response(id: heldID, data: models))
            }
            await signIn.value

            #expect(controller.accountStatus?.isAuthenticated == true)
            #expect(!controller.isBusy)
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

import Foundation
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexAccountControllerTests {
        @Test
        func explicitSignInOpensBrowserAndRefreshesAccount() async {
            let transport = TestCodexAppServerTransport(mode: .loginCompletes)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let urlOpener = TestCodexLoginURLOpener()
            let authenticationChanged = OSAllocatedUnfairLock(initialState: false)
            let controller = CodexAccountController(
                service: service,
                urlOpener: urlOpener,
                authenticationDidChange: { authenticationChanged.withLock { $0 = true } }
            )

            await controller.signIn()

            #expect(urlOpener.openedURLs == [URL(string: "https://chatgpt.com/auth/test")])
            #expect(controller.accountStatus?.isAuthenticated == true)
            #expect(controller.errorMessage == nil)
            #expect(authenticationChanged.withLock { $0 })
            await service.shutdown()
        }

        @Test
        func browserOpenFailureCancelsLoginAndShowsRetryableError() async {
            let transport = TestCodexAppServerTransport(mode: .loginBlocks)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let urlOpener = TestCodexLoginURLOpener(result: false)
            let controller = CodexAccountController(
                service: service, urlOpener: urlOpener, authenticationDidChange: {}
            )

            await controller.signIn()

            #expect(controller.errorMessage == L10n.codexLoginPageCouldNotOpen)
            #expect(await transport.messages().contains {
                $0.objectValue?["method"]?.stringValue == "account/login/cancel"
            })
            #expect(await !(transport.isClosed))
            await service.shutdown()
        }

        @Test
        func activatingChatGPTLoadsLocalStatusWithoutRequiringTheActiveVaultRuntime() async {
            let service = CodexAppServerService(
                transportFactory: { TestCodexAppServerTransport(mode: .models) },
                configurationReadiness: { false }
            )
            let authenticationChanged = OSAllocatedUnfairLock(initialState: false)
            let controller = CodexAccountController(
                service: service,
                authenticationDidChange: { authenticationChanged.withLock { $0 = true } }
            )

            await controller.activateChatGPTSubscription()

            #expect(controller.accountStatus?.isAuthenticated == true)
            #expect(controller.errorMessage == nil)
            #expect(!authenticationChanged.withLock { $0 })
            await service.shutdown()
        }

        @Test
        func signOutRefreshesTheLocalRuntime() async {
            let service = makeTestCodexAppServerService(transportFactory: {
                TestCodexAppServerTransport(mode: .models)
            })
            let authenticationChanged = OSAllocatedUnfairLock(initialState: false)
            let controller = CodexAccountController(service: service, authenticationDidChange: {
                authenticationChanged.withLock { $0 = true }
            })

            await controller.signOut()

            #expect(authenticationChanged.withLock { $0 })
            #expect(controller.errorMessage == nil)
            await service.shutdown()
        }

        @Test(arguments: [
            CodexRuntimeProvider.chatGPTSubscription,
            .databricks(profile: "WORK"),
            .dahlia(connectionID: UUID.v7()),
        ])
        func authenticationChangesOnlyReloadAnActiveChatGPTRuntime(_ provider: CodexRuntimeProvider) async throws {
            let first = TestCodexAppServerTransport(mode: .models)
            let second = TestCodexAppServerTransport(mode: .models)
            let transports = OSAllocatedUnfairLock(initialState: [first, second])
            let service = makeTestCodexAppServerService {
                transports.withLock { $0.removeFirst() }
            }
            let contextStore = CodexRuntimeContextStore()
            contextStore.apply(provider)
            _ = try await service.accountStatus()

            try await CodexAccountController.reloadLocalRuntimeAfterAuthenticationChange(
                contextStore: contextStore, service: service
            )

            #expect(await first.isClosed == (provider == .chatGPTSubscription))
            #expect(contextStore.provider == provider)
            await service.shutdown()
        }

        @Test(.timeLimit(.minutes(1)), arguments: [false, true])
        func committedAuthenticationReloadsBeforeStatusRefreshDespiteViewCancellation(signsIn: Bool) async {
            let transport = TestCodexAppServerTransport(mode: signsIn ? .loginCompletes : .models)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let reloadStarted = AsyncStream.makeStream(of: Void.self)
            let finishReload = AsyncStream.makeStream(of: Void.self)
            let reloaded = OSAllocatedUnfairLock(initialState: false)
            let controller = CodexAccountController(
                service: service,
                urlOpener: TestCodexLoginURLOpener(),
                authenticationDidChange: {
                    let lastMethod = await transport.messages().last?.objectValue?["method"]?.stringValue
                    #expect(lastMethod == (signsIn ? "account/login/start" : "account/logout"))
                    reloadStarted.continuation.yield()
                    for await _ in finishReload.stream { break }
                    try Task.checkCancellation()
                    reloaded.withLock { $0 = true }
                }
            )
            let action = Task {
                if signsIn {
                    await controller.signIn()
                } else {
                    await controller.signOut()
                }
            }
            for await _ in reloadStarted.stream { break }

            action.cancel()
            finishReload.continuation.yield()
            await action.value

            #expect(reloaded.withLock { $0 })
            await service.shutdown()
        }
    }
#endif

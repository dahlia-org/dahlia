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
            let controller = CodexAccountController(service: service, urlOpener: urlOpener)

            await controller.signIn()

            #expect(urlOpener.openedURLs == [URL(string: "https://chatgpt.com/auth/test")])
            #expect(controller.accountStatus?.isAuthenticated == true)
            #expect(controller.errorMessage == nil)
            await service.shutdown()
        }

        @Test
        func browserOpenFailureCancelsLoginAndShowsRetryableError() async {
            let transport = TestCodexAppServerTransport(mode: .loginBlocks)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let urlOpener = TestCodexLoginURLOpener(result: false)
            let controller = CodexAccountController(service: service, urlOpener: urlOpener)

            await controller.signIn()

            #expect(controller.errorMessage == L10n.codexLoginPageCouldNotOpen)
            #expect(await transport.messages().contains {
                $0.objectValue?["method"]?.stringValue == "account/login/cancel"
            })
            #expect(await !(transport.isClosed))
            await service.shutdown()
        }

        @Test
        func activatingChatGPTWaitsForTheVaultRuntimeAndReloadsStatus() async {
            let service = CodexAppServerService {
                TestCodexAppServerTransport(mode: .models)
            }
            let readinessChecked = OSAllocatedUnfairLock(initialState: false)
            let controller = CodexAccountController(
                service: service,
                hasActiveVault: { true },
                runtimeReadiness: {
                    readinessChecked.withLock { $0 = true }
                    return true
                }
            )

            await controller.activateChatGPTSubscription()

            #expect(controller.accountStatus?.isAuthenticated == true)
            #expect(controller.errorMessage == nil)
            #expect(readinessChecked.withLock { $0 })
            await service.shutdown()
        }

        @Test
        func unavailableVaultRuntimeLeavesChatGPTStatusUnloaded() async {
            let service = makeTestCodexAppServerService(transportFactory: {
                TestCodexAppServerTransport(mode: .models)
            })
            let controller = CodexAccountController(
                service: service,
                hasActiveVault: { true },
                runtimeReadiness: { false }
            )

            await controller.activateChatGPTSubscription()

            #expect(controller.accountStatus == nil)
            #expect(controller.errorMessage == L10n.codexAccountConfigurationNotReady)
            await service.shutdown()
        }

        @Test
        func firstRunWithoutAVaultCanLoadChatGPTStatus() async {
            let service = CodexAppServerService {
                TestCodexAppServerTransport(mode: .models)
            }
            let controller = CodexAccountController(
                service: service,
                hasActiveVault: { false },
                runtimeReadiness: { false }
            )

            await controller.activateChatGPTSubscription()

            #expect(controller.accountStatus?.isAuthenticated == true)
            #expect(controller.errorMessage == nil)
            await service.shutdown()
        }
    }
#endif

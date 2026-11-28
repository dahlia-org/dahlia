#if canImport(Testing)
    import AppKit
    import DahliaRuntimeSupport
    import Testing
    @testable import Dahlia

    @MainActor
    struct AgentProviderRegistrationTests {
        typealias Kind = AgentProviderRegistrationView.Kind

        @Test
        func capabilityFiltersMatchTheFunctionsEachProviderOffers() {
            #expect(Kind.matching(nil, subscriptions: PiSubscription.allCases)
                == [.subscription(.openai), .subscription(.anthropic), .google, .databricks])
            #expect(Kind.matching(.models, subscriptions: PiSubscription.allCases)
                == [.subscription(.openai), .subscription(.anthropic), .databricks])
            #expect(Kind.matching(.mcp, subscriptions: PiSubscription.allCases) == [.databricks])
            #expect(Kind.matching(.calendar, subscriptions: PiSubscription.allCases) == [.google, .databricks])
            #expect(Kind.matching(.storage, subscriptions: PiSubscription.allCases) == [.google, .databricks])
        }

        @Test
        func filtersKeepUnavailableSubscriptionsOutOfTheChoices() {
            #expect(Kind.matching(.models, subscriptions: []) == [.databricks])
            #expect(Kind.matching(nil, subscriptions: [.anthropic]) == [.subscription(.anthropic), .google, .databricks])
        }

        @Test
        func onlyProvidersThatAskForMoreExpandBeforeSignIn() {
            #expect(Kind.matching(nil, subscriptions: PiSubscription.allCases).filter(\.needsDetails) == [.google, .databricks])
            for kind in [Kind.google, .databricks] {
                #expect(kind.canOpen(subscriptions: [], isSigningIn: false))
                #expect(!kind.canOpen(subscriptions: [], isSigningIn: true))
            }
        }

        @Test(.timeLimit(.minutes(1)), arguments: PiSubscription.allCases, [false, true])
        func subscriptionRowsWaitForStatusBeforeOfferingSignIn(subscription: PiSubscription, signedIn: Bool) async throws {
            let transport = TestPiTransport { command in
                guard let id = command["id"], command["type"]?.stringValue != "get_available_models" else { return [] }
                return [TestPiTransport.response(id: id)]
            }
            let runtime = TestPiRuntime { _ in transport }
            let controller = PiSubscriptionController(subscription: subscription, service: runtime.service, urlOpener: TestCodexLoginURLOpener())
            let kind = Kind.subscription(subscription)
            #expect(kind.canOpen(subscriptions: [controller], isSigningIn: false))
            #expect(!kind.canOpen(subscriptions: [controller], isSigningIn: true))
            #expect(!kind.canOpen(subscriptions: [], isSigningIn: false))

            let activation = Task { await controller.activate() }
            defer { activation.cancel() }
            let command = await transport.command("get_available_models")
            let id = try #require(command["id"])
            #expect(controller.isCheckingStatus)
            #expect(!kind.canOpen(subscriptions: [controller], isSigningIn: false))

            let models = signedIn ? [TestPiTransport.model(provider: subscription.rawValue, id: "model")] : []
            await transport.emit(TestPiTransport.response(id: id, data: .object(["models": .array(models)])))
            await activation.value
            #expect(!controller.isBusy)
            #expect(kind.canOpen(subscriptions: [controller], isSigningIn: false) == !signedIn)
        }

        @Test
        func providerBrandAssetsAreBundledAndReadable() throws {
            for resource in ["ProviderGoogle", "ProviderAnthropic"] {
                let image = try #require(Bundle.appModule.image(forResource: resource))
                #expect(image.size.width > 0 && image.size.height > 0)
            }
        }
    }
#endif

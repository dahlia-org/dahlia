import DahliaRuntimeSupport
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AppUpdatePolicyTests {
        @Test
        func productionWithFeedStartsUpdater() {
            #expect(AppUpdatePolicy.shouldStartUpdater(
                runtimeProfile: .production,
                feedURL: "https://example.com/appcast.xml"
            ))
        }

        @Test
        func developmentNeverStartsUpdater() {
            #expect(!AppUpdatePolicy.shouldStartUpdater(
                runtimeProfile: .development,
                feedURL: "https://example.com/appcast.xml"
            ))
        }

        @Test(arguments: [nil, "", "   "] as [String?])
        func productionWithoutFeedDoesNotStartUpdater(feedURL: String?) {
            #expect(!AppUpdatePolicy.shouldStartUpdater(runtimeProfile: .production, feedURL: feedURL))
        }
    }
#endif

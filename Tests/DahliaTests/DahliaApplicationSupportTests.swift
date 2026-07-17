import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct DahliaApplicationSupportTests {
        private let baseURL = URL(filePath: "/Users/test/Library/Application Support", directoryHint: .isDirectory)

        @Test
        func productionUsesTheExistingApplicationSupportDirectory() {
            let directoryURL = DahliaApplicationSupport.directoryURL(
                applicationSupportDirectory: baseURL,
                environment: [:]
            )

            #expect(directoryURL == baseURL.appending(path: "Dahlia", directoryHint: .isDirectory))
        }

        @Test
        func developmentUsesOneSharedSeparateApplicationSupportDirectory() {
            let environment = [
                DahliaApplicationSupport.profileEnvironmentKey: DahliaRuntimeProfile.development.rawValue,
            ]
            let firstURL = DahliaApplicationSupport.directoryURL(
                applicationSupportDirectory: baseURL,
                environment: environment
            )
            let secondURL = DahliaApplicationSupport.directoryURL(
                applicationSupportDirectory: baseURL,
                environment: environment
            )

            #expect(firstURL == baseURL.appending(path: "Dahlia-Development", directoryHint: .isDirectory))
            #expect(secondURL == firstURL)
        }

        @Test
        func unrecognizedProfileDoesNotRedirectTheProductionApp() {
            let directoryURL = DahliaApplicationSupport.directoryURL(
                applicationSupportDirectory: baseURL,
                environment: [DahliaApplicationSupport.profileEnvironmentKey: "preview"]
            )

            #expect(directoryURL == baseURL.appending(path: "Dahlia", directoryHint: .isDirectory))
        }

        @Test
        func appAndMeetingAccessHelperResolveTheSameDatabase() {
            let expectedURL = DahliaApplicationSupport.currentDirectoryURL.appending(path: "dahlia.sqlite")

            #expect(AppDatabaseManager.databaseURL == expectedURL)
            #expect(MeetingAccessStore.defaultDatabaseURL == expectedURL)
        }
    }
#endif

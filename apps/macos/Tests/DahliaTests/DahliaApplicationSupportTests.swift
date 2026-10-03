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
                profile: .production,
                applicationSupportDirectory: baseURL
            )

            #expect(directoryURL == baseURL.appending(path: "Dahlia", directoryHint: .isDirectory))
        }

        @Test
        func embeddedDevelopmentProfileAppliesToReleaseBuilds() {
            #expect(
                DahliaApplicationSupport.profile(
                    environment: [:],
                    embeddedProfile: DahliaRuntimeProfile.development.rawValue,
                    isDebugBuild: false
                ) == .development
            )
        }

        @Test
        func developmentEnvironmentAppliesToReleaseHelpers() {
            #expect(
                DahliaApplicationSupport.profile(
                    environment: [
                        DahliaApplicationSupport.profileEnvironmentKey: DahliaRuntimeProfile.development.rawValue,
                    ],
                    embeddedProfile: nil,
                    isDebugBuild: false
                ) == .development
            )
        }

        @Test
        func debugBuildAlwaysUsesDevelopment() {
            #expect(
                DahliaApplicationSupport.profile(
                    environment: [:],
                    embeddedProfile: nil,
                    isDebugBuild: true
                ) == .development
            )
            #expect(
                DahliaApplicationSupport.profile(
                    environment: [
                        DahliaApplicationSupport.profileEnvironmentKey: DahliaRuntimeProfile.production.rawValue,
                    ],
                    embeddedProfile: DahliaRuntimeProfile.production.rawValue,
                    isDebugBuild: true
                ) == .development
            )
        }

        @Test(arguments: [nil, "production", "preview"])
        func missingProductionAndUnrecognizedEmbeddedProfilesUseProduction(_ embeddedProfile: String?) {
            #expect(
                DahliaApplicationSupport.profile(
                    environment: [:],
                    embeddedProfile: embeddedProfile,
                    isDebugBuild: false
                ) == .production
            )
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
            let profile = DahliaApplicationSupport.profile(
                environment: [DahliaApplicationSupport.profileEnvironmentKey: "preview"],
                embeddedProfile: "preview",
                isDebugBuild: false
            )
            let directoryURL = DahliaApplicationSupport.directoryURL(profile: profile, applicationSupportDirectory: baseURL)

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

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
        func developmentDirectorySelectsTheWorktreeDirectory() {
            let worktreeDirectory = URL(filePath: "/Users/test/worktree/.dahlia", directoryHint: .isDirectory)
            let worktreeURL = DahliaApplicationSupport.directoryURL(
                profile: .development,
                developmentDirectory: worktreeDirectory,
                applicationSupportDirectory: baseURL
            )
            let mainCheckoutURL = DahliaApplicationSupport.directoryURL(
                profile: .development,
                developmentDirectory: nil,
                applicationSupportDirectory: baseURL
            )

            #expect(worktreeURL == worktreeDirectory)
            #expect(mainCheckoutURL == baseURL.appending(path: "Dahlia-Development", directoryHint: .isDirectory))
        }

        @Test
        func productionIgnoresTheDevelopmentDirectory() {
            let directoryURL = DahliaApplicationSupport.directoryURL(
                profile: .production,
                developmentDirectory: URL(filePath: "/Users/test/worktree/.dahlia", directoryHint: .isDirectory),
                applicationSupportDirectory: baseURL
            )

            #expect(directoryURL == baseURL.appending(path: "Dahlia", directoryHint: .isDirectory))
        }

        @Test
        func appAndBundledHelpersReadTheSameDevelopmentDirectory() throws {
            let developmentDirectory = "/Users/test/repo with spaces/.dahlia"
            let rootURL = try makeTemporaryApp(developmentDirectory: developmentDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let contentsURL = rootURL.appending(path: "Dahlia.app/Contents", directoryHint: .isDirectory)
            let expectedURL = URL(filePath: developmentDirectory, directoryHint: .isDirectory)

            #expect(DahliaApplicationSupport.developmentDirectory(
                executableURL: contentsURL.appending(path: "MacOS/Dahlia")
            ) == expectedURL)
            #expect(DahliaApplicationSupport.developmentDirectory(
                executableURL: contentsURL.appending(path: "Helpers/dahlia-mcp")
            ) == expectedURL)
            #expect(DahliaApplicationSupport.developmentDirectory(
                executableURL: rootURL.appending(path: ".build/debug/Dahlia")
            ) == nil)
        }

        @Test
        func relativeDevelopmentDirectoryIsIgnored() throws {
            let rootURL = try makeTemporaryApp(developmentDirectory: ".dahlia")
            defer { try? FileManager.default.removeItem(at: rootURL) }

            #expect(DahliaApplicationSupport.developmentDirectory(
                executableURL: rootURL.appending(path: "Dahlia.app/Contents/MacOS/Dahlia")
            ) == nil)
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

        private func makeTemporaryApp(developmentDirectory: String) throws -> URL {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "DahliaApplicationSupportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            let contentsURL = rootURL.appending(path: "Dahlia.app/Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: [DahliaApplicationSupport.developmentDirectoryKey: developmentDirectory],
                format: .xml,
                options: 0
            ).write(to: contentsURL.appending(path: "Info.plist"))
            return rootURL
        }
    }
#endif

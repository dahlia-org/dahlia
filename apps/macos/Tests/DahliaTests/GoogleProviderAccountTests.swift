#if canImport(Testing)
    import AppKit
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct GoogleProviderAccountTests {
        private func account(_ email: String) -> GoogleProviderAccount {
            GoogleProviderAccount(id: .v7(), account: .init(id: email, displayName: email, email: email))
        }

        @Test
        func registeredGoogleRowsPersistIndependentlyAndPreserveOtherProviders() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let databricks = DatabricksConnection(id: .v7(), host: "https://workspace.example")
            try DatabricksOAuthStorage.local(database: { database.dbQueue }).saveConnections([databricks])
            let worker = GoogleProviderAccountWorker(storage: .local(database: { database.dbQueue }), pendingDisconnects: { [] })
            var first = account("first@example.com")
            let second = account("second@example.com")
            try await worker.save(first)
            try await worker.save(second)
            first.name = "Personal"
            try await worker.save(first)
            let model = GoogleProviderAccountsModel(worker: worker)
            await model.activate()
            #expect(await pollUntil {
                Dictionary(uniqueKeysWithValues: model.accounts.map { ($0.id, $0) }) == [first.id: first, second.id: second]
            })
            #expect(await pollUntil { model.controllers.map(\.displayName).sorted() == ["Personal", "Google (second@example.com)"].sorted() })
            try await worker.remove(first.id)
            await model.activate()
            #expect(await pollUntil { model.accounts == [second] })
            #expect(try DatabricksOAuthStorage.local(database: { database.dbQueue }).loadConnections() == [databricks])
            #expect(try await database.dbQueue.read { try DahliaAccountConnectionRecord.fetchCount($0) } == 2)
        }

        @Test
        func calendarChoicesRequireRegistrationAndNeverFallbackToAnotherAccount() throws {
            let first = account("first@example.com")
            let second = account("second@example.com")
            let suite = "RegisteredGoogleChoice.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            ProviderAccountDirectory.$googleAccounts.withValue([]) {
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .unassigned)
                GoogleCalendarProvider.save(.google(accountID: first.id), defaults: defaults)
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .unassigned)
            }
            ProviderAccountDirectory.$googleAccounts.withValue([first, second]) {
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .google(accountID: first.id))
                GoogleCalendarProvider.save(.google(accountID: second.id), defaults: defaults)
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .google(accountID: second.id))
                #expect(ProviderAccountDirectory.accounts.contains(.google(connectionID: first.id)))
                #expect(ProviderAccount.google(connectionID: first.id).capabilities == [.calendar, .storage])
                #expect(!PiProviderConfiguration.bridgedProviderIDs.contains(ProviderAccount.google(connectionID: first.id).piProviderID))
            }
            ProviderAccountDirectory.$googleAccounts.withValue([first]) {
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .unassigned)
            }
        }

        @Test
        func pendingCleanupDiscoveryUsesOnlyValidDisabledGoogleRegistrationIDs() throws {
            let suite = "GoogleCleanupDiscovery.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let pending = UUID.v7()
            let completed = UUID.v7()
            let key = GoogleSignInAdapter.disconnectPendingUserDefaultsKey(for: .calendar.forAccount(pending))
            defaults.set(true, forKey: key)
            defaults.set(false, forKey: GoogleSignInAdapter.disconnectPendingUserDefaultsKey(for: .calendar.forAccount(completed)))
            defaults.set(true, forKey: key + ".invalid")
            defaults.set(true, forKey: GoogleSignInAdapter.disconnectPendingUserDefaultsKey(for: .calendar))
            #expect(GoogleSignInAdapter.pendingDisconnectAccountIDs(defaults: defaults) == [pending])
        }

        @Test
        func googleCredentialsAndPendingDisconnectGenerationsArePerProvider() async {
            let first = UUID.v7()
            let second = UUID.v7()
            let firstCalendar = GoogleAuthSessionKind.calendar.forAccount(first)
            let firstDrive = GoogleAuthSessionKind.drive.forAccount(first)
            let secondCalendar = GoogleAuthSessionKind.calendar.forAccount(second)
            #expect(firstCalendar.keychainKey == firstDrive.keychainKey)
            #expect(firstCalendar.sessionDidChangeNotification == firstDrive.sessionDidChangeNotification)
            #expect(firstCalendar.keychainKey != secondCalendar.keychainKey)
            #expect(firstCalendar.sessionDidChangeNotification != secondCalendar.sessionDidChangeNotification)
            #expect(GoogleSignInAdapter.disconnectPendingUserDefaultsKey(for: firstCalendar)
                != GoogleSignInAdapter.disconnectPendingUserDefaultsKey(for: secondCalendar))
            let worker = GoogleKeychainWorker()
            let (_, firstGeneration) = await worker.snapshot(for: firstCalendar) {}
            let (_, secondGeneration) = await worker.snapshot(for: secondCalendar) {}
            await worker.beginDisconnect(for: firstCalendar)
            #expect(await worker.performIfCurrent(for: firstDrive, generation: firstGeneration) {} == false)
            #expect(await worker.performIfCurrent(for: secondCalendar, generation: secondGeneration) {})
            await worker.finishDisconnect(for: firstCalendar)
        }

        @Test
        func routedCalendarUsesOnlyTheSelectedGoogleAndDisconnectKeepsRegistration() async throws {
            let first = account("first@example.com")
            let second = account("second@example.com")
            let suite = "RoutedGoogleAccounts.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            try await ProviderAccountDirectory.$googleAccounts.withValue([first, second]) {
                let firstSignIn = RegisteredGoogleSignIn(account: first.account)
                let secondSignIn = RegisteredGoogleSignIn(account: second.account)
                let calendar = DatabricksProxyGoogleSignInProvider(
                    directProviderFactory: { $0.id == first.id ? firstSignIn : secondSignIn }, userDefaults: defaults,
                    connectionChangeNotification: Notification.Name("UnusedGoogleConnection.\(UUID())")
                )
                #expect(!calendar.isConfigured)
                #expect(await calendar.hasPreviousSignIn == false)
                GoogleCalendarProvider.save(.google(accountID: second.id), defaults: defaults)
                #expect(try await calendar.restorePreviousSignIn().account == second.account)
                #expect(firstSignIn.restoreCount == 0)
                #expect(secondSignIn.restoreCount == 1)
                try await calendar.disconnect()
                #expect(await calendar.hasPreviousSignIn == false)
                #expect(secondSignIn.disconnectCount == 0)
                let drive = DatabricksProxyGoogleSignInProvider(
                    sessionKind: .drive, directProviderFactory: { $0.id == first.id ? firstSignIn : secondSignIn }, userDefaults: defaults,
                    connectionChangeNotification: Notification.Name("UnusedGoogleDriveConnection.\(UUID())")
                )
                #expect(await drive.hasPreviousSignIn)
                GoogleCalendarProvider.save(.google(accountID: first.id), defaults: defaults)
                #expect(try await calendar.restorePreviousSignIn().account == first.account)
                #expect(secondSignIn.disconnectCount == 0)
            }
        }
    }

    @MainActor
    private final class RegisteredGoogleSignIn: GoogleSignInProviding {
        let account: GoogleCalendarAccount
        let isConfigured = true
        let hasPreviousSignIn = true
        let sessionDidChangeNotification = Notification.Name("RegisteredGoogleSignIn.\(UUID())")
        var restoreCount = 0
        var disconnectCount = 0
        init(account: GoogleCalendarAccount) { self.account = account }
        func restorePreviousSignIn() async throws -> GoogleSession {
            restoreCount += 1
            return GoogleSession(account: account, accessToken: "fixture", grantedScopes: GoogleOAuthScope.calendar.union(GoogleOAuthScope.drive))
        }

        func signIn(withPresentingWindow _: NSWindow, requestedScopes _: Set<String>) async throws -> GoogleSession {
            try await restorePreviousSignIn()
        }

        func refreshCurrentSession() async throws -> GoogleSession? { try await restorePreviousSignIn() }
        func disconnect() async throws { disconnectCount += 1 }
    }
#endif

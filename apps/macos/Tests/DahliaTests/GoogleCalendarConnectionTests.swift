import AppKit
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct GoogleCalendarConnectionTests {
        @Test(arguments: [false, true])
        func legacySelectionBelongsOnlyToTheOriginalDatabricksAccount(explicitEmpty: Bool) throws {
            let suite = "GoogleCalendarConnectionTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let original = UUID.v7()
            let other = UUID.v7()
            defaults.set(original.uuidString, forKey: SingleAccountMigration.sourceKey)
            defaults.set("[\"primary\"]", forKey: GoogleCalendarStore.accountSelectedCalendarIDsKey)
            if explicitEmpty {
                defaults.set("[]", forKey: "\(GoogleCalendarStore.accountSelectedCalendarIDsKey).databricks.\(original.uuidString)")
            }
            func store(_ id: UUID) -> GoogleCalendarStore {
                GoogleCalendarStore(
                    signInProvider: SignIn(), provider: .databricks(connectionID: id), initiallyActive: false,
                    apiClient: Client(), userDefaults: defaults
                )
            }
            #expect(store(original).selectedCalendarIDs == (explicitEmpty ? [] : ["primary"]))
            GoogleCalendarProvider.save(.databricks(connectionID: other), defaults: defaults)
            #expect(store(other).selectedCalendarIDs.isEmpty)
            #expect(store(original).selectedCalendarIDs == (explicitEmpty ? [] : ["primary"]))
        }

        @Test(arguments: [false, true])
        func fixedConnectionsKeepSeparateSelectionsAndDiscardADisabledFetch(google: Bool) async throws {
            let suite = "GoogleCalendarConnectionTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let firstID = UUID.v7()
            let secondID = UUID.v7()
            let firstRoute: GoogleCalendarProvider = google ? .google(accountID: firstID) : .databricks(connectionID: firstID)
            let secondRoute: GoogleCalendarProvider = google ? .google(accountID: secondID) : .databricks(connectionID: secondID)
            let kind = google ? "google" : "databricks"
            defaults.set("[\"primary\"]", forKey: "\(GoogleCalendarStore.accountSelectedCalendarIDsKey).\(kind).\(firstID.uuidString)")
            defaults.set("[\"team\"]", forKey: "\(GoogleCalendarStore.accountSelectedCalendarIDsKey).\(kind).\(secondID.uuidString)")
            let firstAPI = Client()
            let first = GoogleCalendarStore(signInProvider: SignIn(), provider: firstRoute, apiClient: firstAPI, userDefaults: defaults)
            let second = GoogleCalendarStore(signInProvider: SignIn(), provider: secondRoute, apiClient: Client(), userDefaults: defaults)
            await first.restoreSessionIfNeeded()
            await second.restoreSessionIfNeeded()
            #expect(first.selectedCalendarIDs == ["primary"])
            #expect(second.selectedCalendarIDs == ["team"])
            #expect(first.upcomingEvents.map(\.calendarID) == ["primary"])
            #expect(second.upcomingEvents.map(\.calendarID) == ["team"])
            firstAPI.suspends = true
            let refresh = Task { await first.refreshIfNeeded(force: true) }
            await firstAPI.waitUntilSuspended()
            first.setActive(false)
            firstAPI.resume()
            await refresh.value
            #expect(first.upcomingEvents.isEmpty)
            #expect(second.state == .loaded)
            #expect(second.selectedCalendarIDs == ["team"])
            #expect(second.upcomingEvents.map(\.calendarID) == ["team"])
            let reopened = GoogleCalendarStore(
                signInProvider: SignIn(),
                provider: firstRoute,
                initiallyActive: false,
                apiClient: Client(),
                userDefaults: defaults
            )
            #expect(reopened.selectedCalendarIDs == ["primary"])
        }
    }

    @MainActor
    private final class SignIn: GoogleSignInProviding {
        let isConfigured = true
        let hasPreviousSignIn = true
        let sessionDidChangeNotification = Notification.Name("CalendarConnectionSignIn.\(UUID())")
        let session = GoogleSession(
            account: .init(id: "fixture", displayName: "Fixture", email: "fixture@example.com"), accessToken: "fixture",
            grantedScopes: GoogleOAuthScope.calendar
        )
        func restorePreviousSignIn() async throws -> GoogleSession { session }
        func refreshCurrentSession() async throws -> GoogleSession? { session }
        func signIn(withPresentingWindow _: NSWindow, requestedScopes _: Set<String>) async throws -> GoogleSession { session }
        func disconnect() async throws {}
    }

    @MainActor
    private final class Client: GoogleCalendarAPIClientProviding {
        var suspends = false
        private var pending: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        func fetchCalendarList(session _: GoogleSession) async throws -> [CalendarListItem] {
            ["primary", "team"].map { CalendarListItem(id: $0, title: $0, colorHex: nil, isPrimary: $0 == "primary") }
        }

        func fetchUpcomingEvents(
            session _: GoogleSession,
            calendars: [CalendarListItem],
            now: Date,
            daysAhead _: Int
        ) async throws -> [CalendarEvent] {
            if suspends {
                await withCheckedContinuation { continuation in
                    pending = continuation
                    started?.resume()
                    started = nil
                }
                // Intentionally ignore cancellation: the store must also reject a late transport completion.
            }
            return calendars.map {
                CalendarEvent(
                    id: "\($0.id)::event", calendarID: $0.id, calendarName: $0.title, calendarColorHex: nil,
                    platformId: "event", title: "Event", description: "", icalUid: "event@\($0.id)", startDate: now,
                    endDate: now.addingTimeInterval(3600), isAllDay: false, conferenceURI: nil
                )
            }
        }

        func waitUntilSuspended() async {
            if pending != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func resume() { pending?.resume()
            pending = nil
        }
    }
#endif

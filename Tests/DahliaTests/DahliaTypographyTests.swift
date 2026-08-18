import AppKit
import Foundation
import SwiftUI
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct DahliaTypographyTests {
        @Test
        func rolesUseConfiguredOffsets() {
            let expectedAtDefault: [DahliaFontRole: CGFloat] = [
                .displayTitle: 22,
                .sectionTitle: 18,
                .subsectionTitle: 16,
                .body: 14,
                .secondary: 12,
                .metadata: 10,
            ]

            for (role, expected) in expectedAtDefault {
                #expect(role.pointSize(baseSize: 14) == expected)
            }
            #expect(DahliaFontRole.body.pointSize(baseSize: 12) == 12)
            #expect(DahliaFontRole.metadata.pointSize(baseSize: 12) == 8)
            #expect(DahliaFontRole.displayTitle.pointSize(baseSize: 20) == 28)
        }

        @Test
        func baseSizeIsLimitedToSupportedRange() {
            #expect(AppSettings.defaultInterfaceFontSize == 14)
            #expect(DahliaTypography.normalizedBaseSize(8) == 12)
            #expect(DahliaTypography.normalizedBaseSize(16) == 16)
            #expect(DahliaTypography.normalizedBaseSize(24) == 20)
        }

        @Test
        func meetingSidebarRowStyleDefaultsToStandard() {
            #expect(MeetingSidebarRowStyle.resolved(rawValue: "standard") == .standard)
            #expect(MeetingSidebarRowStyle.resolved(rawValue: "compact") == .compact)
            #expect(MeetingSidebarRowStyle.resolved(rawValue: "unknown") == .standard)
            #expect(MeetingSidebarRowStyle.standard.label == L10n.standard)
            #expect(MeetingSidebarRowStyle.compact.label == L10n.compact)
        }

        @Test
        @MainActor
        func projectTimestampAlwaysUsesGregorianCalendar() throws {
            let timeZone = try #require(TimeZone(secondsFromGMT: 9 * 60 * 60))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let date = try #require(calendar.date(from: DateComponents(
                year: 2026,
                month: 3,
                day: 29,
                hour: 10,
                minute: 23
            )))

            #expect(MeetingSidebarRow.projectTimestamp(for: date, timeZone: timeZone) == "2026-03-29 10:23")
        }

        @Test
        @MainActor
        func fixedSymbolsIgnoreConfiguredFontSize() {
            func renderedSize(baseSize: CGFloat) -> CGSize {
                NSHostingView(rootView: VStack {
                    Image(systemName: "star.fill")
                        .dahliaFixedSymbol()
                }
                .font(.system(size: baseSize))).fittingSize
            }

            #expect(renderedSize(baseSize: 12) == renderedSize(baseSize: 20))
        }
    }
#endif

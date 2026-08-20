import AppKit
import Foundation
import SwiftUI
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct DahliaTypographyTests {
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
        func fixedSymbolsUseBodyStyleIndependentlyOfParentStyle() {
            func renderedSize(parentStyle: Font) -> CGSize {
                NSHostingView(rootView: VStack {
                    Image(systemName: "star.fill")
                        .dahliaFixedSymbol()
                }
                .font(parentStyle)).fittingSize
            }

            #expect(renderedSize(parentStyle: .caption) == renderedSize(parentStyle: .title))
        }

        @Test
        @MainActor
        func lightSecondaryTextMeetsNormalTextContrast() throws {
            let appearance = try #require(NSAppearance(named: .aqua))
            let color = resolved(DahliaDesign.secondaryTextNSColor, with: appearance)

            #expect(contrastAgainstWhite(color) >= 4.5)
        }

        @Test
        func sidebarHighlightStrengthensWithIncreasedContrast() {
            #expect(
                DahliaDesign.sidebarHighlightOpacity(for: .increased)
                    > DahliaDesign.sidebarHighlightOpacity(for: .standard)
            )
        }

        @MainActor
        private func resolved(_ color: NSColor, with appearance: NSAppearance) -> NSColor {
            var resolvedColor = color
            appearance.performAsCurrentDrawingAppearance {
                resolvedColor = color.usingColorSpace(.sRGB) ?? color
            }
            return resolvedColor
        }

        private func contrastAgainstWhite(_ color: NSColor) -> CGFloat {
            let components = [color.redComponent, color.greenComponent, color.blueComponent].map { component in
                component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            let luminance = 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
            return 1.05 / (luminance + 0.05)
        }
    }
#endif

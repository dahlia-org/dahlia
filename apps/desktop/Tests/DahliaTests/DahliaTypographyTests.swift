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
        @MainActor
        func primaryButtonMeetsTextContrastInEveryEnabledState() throws {
            let appearances = try [
                NSAppearance.Name.aqua,
                .darkAqua,
                .accessibilityHighContrastAqua,
                .accessibilityHighContrastDarkAqua,
            ].map { try #require(NSAppearance(named: $0)) }
            let states: [DahliaDesign.Button.InteractionState] = [.normal, .hovered, .pressed]

            for appearance in appearances {
                for state in states {
                    let color = resolved(DahliaDesign.primaryButtonBackgroundNSColor(for: state), with: appearance)
                    #expect(contrast(color, against: .white) >= 4.5)
                }
            }
        }

        @Test
        func sidebarHighlightStrengthensWithIncreasedContrast() {
            #expect(DahliaDesign.sidebarHighlightOpacity(for: .standard) == 0.10)
            #expect(DahliaDesign.sidebarHighlightOpacity(for: .increased) == 0.20)
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
            contrast(color, against: .white)
        }

        private func contrast(_ first: NSColor, against second: NSColor) -> CGFloat {
            let luminances = [first, second].map { color in
                relativeLuminance(color)
            }.sorted()
            return (luminances[1] + 0.05) / (luminances[0] + 0.05)
        }

        private func relativeLuminance(_ color: NSColor) -> CGFloat {
            let color = color.usingColorSpace(.sRGB) ?? color
            let components = [color.redComponent, color.greenComponent, color.blueComponent].map { component in
                component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
        }
    }
#endif

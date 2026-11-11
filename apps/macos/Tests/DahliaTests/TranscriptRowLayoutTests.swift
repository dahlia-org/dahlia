#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct TranscriptRowLayoutTests {
        @Test(arguments: ["00:01:19", "123:45:56"])
        func timestampKeepsTheRowOnOneLine(timestamp: String) {
            let segment = TranscriptSegment(startTime: .distantPast, text: "Transcript", isConfirmed: true)
            let row = NSHostingView(rootView: TranscriptRowView(
                segment: segment,
                timestamp: timestamp,
                showsTranslatedText: false,
                allowsTextSelection: false
            ).frame(width: 320))
            let singleLine = NSHostingView(rootView: Text(segment.displayText)
                .font(.dahliaBody)
                .padding(.vertical, 4))

            #expect(row.fittingSize.height == singleLine.fittingSize.height)
        }
    }
#endif

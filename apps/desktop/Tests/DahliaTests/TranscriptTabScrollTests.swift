#if canImport(Testing)
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct TranscriptTabScrollTests {
        @Test
        func latestFollowTargetsTranscriptInsteadOfTallFooter() {
            let store = TranscriptStore()
            let view = TranscriptTabView(
                store: store,
                allowsTextSelection: false,
                showsTranslatedText: false,
                retryInitialMeetingLoad: {},
                header: { EmptyView() },
                footer: { Color.clear.frame(height: 2000) }
            )
            var position = ScrollPosition(idType: TranscriptSegment.ID.self)
            view.scrollToLatest(in: &position)
            #expect(position.viewID(type: TranscriptSegment.ID.self) == nil)

            let confirmed = TranscriptSegment(startTime: .now, text: "confirmed", isConfirmed: true)
            store.loadSegments([confirmed])
            view.scrollToLatest(in: &position)
            #expect(position.viewID(type: TranscriptSegment.ID.self) == confirmed.id)
            #expect(position.edge == nil)

            let preview = TranscriptSegment(startTime: confirmed.startTime.addingTimeInterval(1), text: "preview")
            store.loadSegments([confirmed, preview])
            view.scrollToLatest(in: &position)
            #expect(position.viewID(type: TranscriptSegment.ID.self) == preview.id)
        }
    }
#endif

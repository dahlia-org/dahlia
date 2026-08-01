import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatMarkdownTextViewTests {
        @Test
        func firstMeasurementIsExactWithoutWaiting() throws {
            let reference = try #require(Self.makeTextView().measuredHeight(constrainedTo: 400))
            let textView = Self.makeTextView()

            #expect(reference > 0)
            #expect(textView.measuredHeight(constrainedTo: 400) == reference)
        }

        @Test
        func widthChangeReturnsAnAreaPreservingEstimate() throws {
            let textView = Self.makeTextView()
            let wideHeight = try #require(textView.measuredHeight(constrainedTo: 400))

            let estimate = try #require(textView.measuredHeight(constrainedTo: 200))

            // 同期レイアウトをやり直さず、幅の比で高さを見積もって即座に返す。
            #expect(estimate == (wideHeight * 400 / 200).rounded(.up))
        }

        @Test
        func widthChangeConvergesToTheExactHeight() async throws {
            let exact = try #require(Self.makeTextView().measuredHeight(constrainedTo: 200))
            let textView = Self.makeTextView()
            _ = textView.measuredHeight(constrainedTo: 400)
            _ = textView.measuredHeight(constrainedTo: 200)

            let settled = try await Self.settledHeight(of: textView, width: 200, expecting: exact)

            #expect(settled == exact)
        }

        @Test
        func burstOfWidthChangesConvergesToTheFinalWidth() async throws {
            let exact = try #require(Self.makeTextView().measuredHeight(constrainedTo: 240))
            let textView = Self.makeTextView()

            // リサイズドラッグのように 1 フレーム未満の間隔で幅が変わり続ける状況。
            let widths: [CGFloat] = [400, 360, 320, 280, 240]
            for width in widths {
                _ = textView.measuredHeight(constrainedTo: width)
            }

            let settled = try await Self.settledHeight(of: textView, width: 240, expecting: exact)

            #expect(settled == exact)
        }

        private static func makeTextView() -> CodexChatSelectableTextView {
            let textView = CodexChatSelectableTextView.makeConfigured()
            let blocks = (0 ..< 20).map { index in
                CodexChatMarkdownRenderedBlock.paragraph(AttributedString(
                    "Paragraph \(index): " + String(repeating: "measurement sample text ", count: 5)
                ))
            }
            textView.setBlocks(blocks)
            return textView
        }

        private static func settledHeight(
            of textView: CodexChatSelectableTextView,
            width: CGFloat,
            expecting expected: CGFloat
        ) async throws -> CGFloat {
            for _ in 0 ..< 200 {
                let height = try #require(textView.measuredHeight(constrainedTo: width))
                if height == expected {
                    return height
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            return try #require(textView.measuredHeight(constrainedTo: width))
        }
    }
#endif

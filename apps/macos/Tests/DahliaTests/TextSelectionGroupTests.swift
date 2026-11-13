#if canImport(Testing)
    import AppKit
    import DahliaRuntimeSupport
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct TextSelectionGroupTests {
        @Test
        func pagingKeepsSelectionWhileSelectedRowsAndTheirOrderSurvive() {
            let selection = TextSelectionGroup()
            selection.update(rows: [("a", "first"), ("b", "middle"), ("c", "last")])
            let view = makeTextView(id: "a", text: "first", y: 0, selection: selection)
            selection.begin(at: .init(id: "a", offset: 2))
            selection.extend(to: .init(id: "c", offset: 2))
            let selected = selection.selectedText
            selection.update(rows: [("before", "new"), ("a", "first"), ("b", "middle"), ("c", "last"), ("after", "new")])
            #expect(selection.selectedText == selected)
            #expect(view.selectedRange() == NSRange(location: 2, length: 3))
            selection.update(rows: [("a", "first"), ("b", "changed"), ("c", "last")])
            #expect(selection.selectedText == nil)
            #expect(view.selectedRange().length == 0)
        }

        @Test
        func selectionClearsIfPagingEvictsOrReordersSelectedRows() {
            for updated in [
                [("b", "middle"), ("c", "last")],
                [("a", "first"), ("c", "last"), ("b", "middle")],
                [("a", "first"), ("new", "inserted"), ("b", "middle"), ("c", "last")],
            ] {
                let selection = TextSelectionGroup()
                selection.update(rows: [("a", "first"), ("b", "middle"), ("c", "last")])
                selection.begin(at: .init(id: "a", offset: 2))
                selection.extend(to: .init(id: "c", offset: 2))
                selection.update(rows: updated)
                #expect(selection.selectedText == nil)
            }
        }

        @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
        func allRowsUseTheSameSelectionColorAndDimTogether(appearanceName: NSAppearance.Name) throws {
            let window = SelectionTestWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: appearanceName)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            window.contentView = root
            let selection = TextSelectionGroup()
            selection.update(rows: [("first", "first row"), ("last", "last row")])
            let first = makeTextView(id: "first", text: "first row", y: 100, selection: selection)
            let last = makeTextView(id: "last", text: "last row", y: 20, selection: selection)
            root.addSubview(first)
            root.addSubview(last)
            #expect(window.makeFirstResponder(first))
            selection.selectAll()
            #expect(selection.isEmphasized(in: window))
            let activeFirst = try selectionBackground(in: first)
            let activeLast = try selectionBackground(in: last)
            #expect(colorsMatch(activeFirst, activeLast))
            window.simulatedKeyWindow = false
            #expect(!selection.isEmphasized(in: window))
            let inactiveFirst = try selectionBackground(in: first)
            let inactiveLast = try selectionBackground(in: last)
            #expect(colorsMatch(inactiveFirst, inactiveLast))
            #expect(!colorsMatch(activeLast, inactiveLast))
        }

        private func selectionBackground(in view: SelectableTextView) throws -> NSColor {
            let manager = try #require(view.layoutManager)
            let container = try #require(view.textContainer)
            let space = (view.string as NSString).range(of: " ")
            let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: space, actualCharacterRange: nil), in: container)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try #require(bitmap.colorAt(x: Int(rect.midX), y: Int(rect.midY))?.usingColorSpace(.sRGB))
        }

        private func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
            abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01 &&
                abs(lhs.blueComponent - rhs.blueComponent) < 0.01
        }

        @Test
        func nativeTextExposesItsFirstLineBaselineEvenWhenItWraps() {
            let font = NSFont.dahliaBody
            let text = NSAttributedString(string: String(repeating: "複数行の本文です。", count: 30), attributes: [.font: font])
            let host = NSHostingView(rootView: SelectionBaselineLayout {
                SelectableText(id: "body", text: text, selection: TextSelectionGroup())
            })
            #expect(abs(host.fittingSize.height - font.ascender) < 1)
        }

        @Test
        func selectableTranscriptStillWrapsAndShowsTranslations() throws {
            let segment = TranscriptSegment(
                startTime: .now,
                text: String(repeating: "長い発話です。", count: 30),
                translatedText: "Translation",
                isConfirmed: true
            )
            let selection = TextSelectionGroup()
            selection.update(segments: [segment], showsTranslatedText: true)
            let host = NSHostingView(rootView: TranscriptRowView(
                segment: segment,
                timestamp: "00:00:00",
                showsTranslatedText: true,
                allowsTextSelection: true,
                selection: selection
            ).frame(width: 320))
            host.frame = NSRect(x: 0, y: 0, width: 320, height: host.fittingSize.height)
            host.layoutSubtreeIfNeeded()
            let text = try #require(textViews(in: host).first)
            #expect(text.string == segment.text + "\nTranslation")
            #expect(text.frame.height > NSFont.dahliaBody.pointSize * 2)
            #expect(!text.isEditable && text.isSelectable)
        }

        private func textViews(in view: NSView) -> [SelectableTextView] {
            if let text = view as? SelectableTextView { return [text] }
            return view.subviews.flatMap { textViews(in: $0) }
        }

        @Test
        func summaryRowsKeepDisplayOrderAndStripMarkdownWithoutMergingRepeatedText() {
            let paragraph = SummaryBlock.paragraph("**同じ文**")
            let list = SummaryBlock.bulletedList(items: ["同じ文", "次の項目"])
            let table = SummaryBlock.table(headers: ["列"], rows: [["値"]])
            let document = SummaryDocument(title: "Meeting", sections: [
                SummarySection(id: .v7(), heading: "見出し", blocks: [paragraph, list, table]),
            ], actionItems: [SummaryActionItem(title: "確認", assignee: "person_name")])
            let rows = SummaryTextSelectionRows.rows(for: document)
            #expect(rows.map(\.text) == ["見出し", "同じ文", "同じ文", "次の項目", "列", "値", L10n.actionItems, "確認", "(person_name)"])
            #expect(Set(rows.map(\.id)).count == rows.count)
            let selection = TextSelectionGroup()
            selection.update(rows: rows)
            selection.begin(at: .init(id: paragraph.id.uuidString, offset: 0))
            selection.extend(to: .init(id: "\(table.id)-0-0", offset: 1))
            #expect(selection.selectedText == "同じ文\n同じ文\n次の項目\n列\n値")
        }

        @Test
        func draggingUsesTheOtherTextViewAndCopiesOneContinuousRange() throws {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            window.contentView = root
            let selection = TextSelectionGroup()
            selection.update(rows: [("first", "first row"), ("last", "last row")])
            let first = makeTextView(id: "first", text: "first row", y: 100, selection: selection)
            let last = makeTextView(id: "last", text: "last row", y: 20, selection: selection)
            root.addSubview(first)
            root.addSubview(last)
            let location = last.convert(NSPoint(x: 25, y: 8), to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            selection.begin(at: .init(id: "first", offset: 2))
            selection.extend(event: event, from: first, initialRange: NSRange(location: 2, length: 0), granularity: .selectByCharacter)
            let end = last.characterIndexForInsertion(at: last.convert(location, from: nil))
            #expect(end > 0)
            #expect(first.selectedRange() == NSRange(location: 2, length: 7))
            #expect(last.selectedRange() == NSRange(location: 0, length: end))
            #expect(selection.selectedText == "rst row\n" + (last.string as NSString).substring(to: end))
        }

        private func makeTextView(id: String, text: String, y: CGFloat, selection: TextSelectionGroup) -> SelectableTextView {
            let view = SelectableTextView.makeConfigured()
            view.frame = NSRect(x: 0, y: y, width: 300, height: 40)
            view.selectionID = id
            view.selection = selection
            view.string = text
            view.font = .dahliaBody
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
            if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
            selection.register(view)
            return view
        }

        @Test
        func selectionSpansRowsInBothDirectionsIncludingUnmountedRows() {
            let segments = ["最初の発話", "途中😀の発話", "最後の発話"].map {
                TranscriptSegment(startTime: .now, text: $0, isConfirmed: true)
            }
            let selection = TextSelectionGroup()
            selection.update(segments: segments, showsTranslatedText: false)
            selection.begin(at: .init(id: segments[0].id.uuidString, offset: 2))
            selection.extend(to: .init(id: segments[2].id.uuidString, offset: 2))
            #expect(selection.selectedText == "の発話\n途中😀の発話\n最後")
            #expect(selection.range(for: segments[1].id.uuidString) == NSRange(location: 0, length: 7))

            selection.begin(at: .init(id: segments[2].id.uuidString, offset: 2))
            selection.extend(to: .init(id: segments[0].id.uuidString, offset: 2))
            #expect(selection.selectedText == "の発話\n途中😀の発話\n最後")
        }

        @Test
        func nativeSingleRowSelectionSurvivesMouseUpAndUnchangedUpdates() {
            let segment = TranscriptSegment(startTime: .now, text: "single row")
            let selection = TextSelectionGroup()
            selection.update(segments: [segment], showsTranslatedText: false)
            let view = SelectableTextView()
            view.selectionID = segment.id.uuidString
            view.string = segment.text
            selection.register(view)
            selection.begin(at: .init(id: segment.id.uuidString, offset: 0))
            view.setSelectedRange(NSRange(location: 0, length: 6))
            selection.finish()
            selection.update(segments: [segment], showsTranslatedText: false)
            selection.register(view)
            #expect(view.selectedRange() == NSRange(location: 0, length: 6))
            #expect(selection.selectedText == nil)
        }

        @Test
        func translatedRowsAndContentChangesUseCurrentDisplayText() {
            var first = TranscriptSegment(startTime: .now, text: "原文", translatedText: "Translation")
            let last = TranscriptSegment(startTime: .now, text: "次")
            let selection = TextSelectionGroup()
            selection.update(segments: [first, last], showsTranslatedText: true)
            selection.begin(at: .init(id: first.id.uuidString, offset: 0))
            selection.extend(to: .init(id: last.id.uuidString, offset: 1))
            #expect(selection.selectedText == "原文\nTranslation\n次")
            first.text = "更新"
            selection.update(segments: [first, last], showsTranslatedText: true)
            #expect(selection.selectedText == nil)
        }

        @Test
        func mountedRowsReceiveAndClearTheSharedRange() {
            let segments = ["first", "last"].map { TranscriptSegment(startTime: .now, text: $0) }
            let selection = TextSelectionGroup()
            selection.update(segments: segments, showsTranslatedText: false)
            let view = SelectableTextView()
            view.selectionID = segments[1].id.uuidString
            view.string = segments[1].text
            selection.register(view)
            selection.begin(at: .init(id: segments[0].id.uuidString, offset: 2))
            selection.extend(to: .init(id: segments[1].id.uuidString, offset: 3))
            #expect(view.selectedRange() == NSRange(location: 0, length: 3))
            selection.clear()
            #expect(view.selectedRange().length == 0)
            #expect(selection.selectAll())
            #expect(selection.selectedText == "first\nlast")
            #expect(view.selectedRange() == NSRange(location: 0, length: 4))
        }
    }

    @MainActor
    private final class SelectionTestWindow: NSWindow {
        var simulatedKeyWindow = true
        override var isKeyWindow: Bool { simulatedKeyWindow }
    }

    private struct SelectionBaselineLayout: Layout {
        func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
            guard let first = subviews.first else { return .zero }
            let dimensions = first.dimensions(in: ProposedViewSize(width: 300, height: nil))
            return CGSize(width: 300, height: dimensions[.firstTextBaseline])
        }

        func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: 300, height: nil))
        }
    }
#endif

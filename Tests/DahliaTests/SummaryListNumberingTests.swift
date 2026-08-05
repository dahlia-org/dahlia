@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    struct SummaryListNumberingTests {
        @Test
        func numberedListCountersContinueAndResetPerIndent() {
            #expect(SummaryListNumbering.numbers(for: [0, 1, 1, 0, 1]) == [1, 1, 2, 2, 1])
        }
    }
#endif

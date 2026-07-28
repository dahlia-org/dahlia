import Darwin
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexAppServerProcessTransportTests {
        @Test
        func exchangesMultipleLinesWithLongLivedChild() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: []
            )

            try await transport.sendLine(Data("first".utf8))
            #expect(try await transport.receiveLine() == Data("first".utf8))
            try await transport.sendLine(Data("second".utf8))
            #expect(try await transport.receiveLine() == Data("second".utf8))
            await transport.close()
        }

        @Test
        func closeReapsLongLivedChild() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: []
            )
            let processID = await transport.processIdentifierForTesting()

            #expect(Darwin.kill(processID, 0) == 0)
            await transport.close()
            let probeResult = Darwin.kill(processID, 0)
            let probeError = errno
            #expect(probeResult == -1)
            #expect(probeError == ESRCH)
        }

        @Test
        func cleanOutputEOFIncludesStderrTail() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'codex panic detail' >&2"]
            )

            do {
                _ = try await transport.receiveLine()
                Issue.record("Expected process exit")
            } catch let error as CodexAppServerError {
                guard case let .processExited(detail) = error else {
                    Issue.record("Unexpected error: \(error)")
                    await transport.close()
                    return
                }
                #expect(detail?.contains("codex panic detail") == true)
            }
            await transport.close()
        }

        @Test
        func stdoutBufferHasAnUpperBound() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "i=0; while [ $i -lt 1200 ]; do printf '%s\\n' $i; i=$((i+1)); done; read _"]
            )

            await transport.waitUntilOutputBufferOverflowForTesting()
            await #expect(throws: CodexAppServerError.outputBufferOverflow) {
                _ = try await transport.receiveLine()
            }
            await transport.close()
        }

        @Test
        func stdoutBufferAcceptsDocumentedCapacityInFIFOOrder() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: []
            )
            let expectedLines = (0 ..< 1024).map { Data(String($0).utf8) }

            await transport.enqueueOutputLinesForTesting(expectedLines)

            var receivedLines: [Data] = []
            for _ in expectedLines.indices {
                try receivedLines.append(#require(await transport.receiveLine()))
            }
            #expect(receivedLines == expectedLines)
            await transport.close()
        }

        @Test
        func stdoutBufferRejectsLineAfterDocumentedCapacity() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: []
            )
            let lines = (0 ... 1024).map { Data(String($0).utf8) }

            await transport.enqueueOutputLinesForTesting(lines)

            await #expect(throws: CodexAppServerError.outputBufferOverflow) {
                _ = try await transport.receiveLine()
            }
            await transport.close()
        }

        @Test
        func stdoutBufferPreservesFIFOWhenReplenishedAfterCompaction() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: []
            )
            let initialLines = (0 ..< 1024).map { Data(String($0).utf8) }
            let replenishedLines = (1024 ..< 1536).map { Data(String($0).utf8) }

            await transport.enqueueOutputLinesForTesting(initialLines)
            for expectedLine in initialLines.prefix(512) {
                #expect(try await transport.receiveLine() == expectedLine)
            }
            await transport.enqueueOutputLinesForTesting(replenishedLines)

            let expectedRemainder = Array(initialLines.dropFirst(512)) + replenishedLines
            var receivedRemainder: [Data] = []
            for _ in expectedRemainder.indices {
                try receivedRemainder.append(#require(await transport.receiveLine()))
            }
            #expect(receivedRemainder == expectedRemainder)
            await transport.close()
        }

        @Test
        func stdoutBufferReleasesConsumedPayloadsBeforeCompaction() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: []
            )
            let line = Data(repeating: 0x61, count: 64)
            await transport.enqueueOutputLinesForTesting(Array(repeating: line, count: 1024))

            for _ in 0 ..< 256 {
                _ = try await transport.receiveLine()
            }

            let state = await transport.outputBufferStateForTesting()
            #expect(state.unreadLineCount == 768)
            #expect(state.retainedByteCount == 768 * line.count)
            await transport.close()
        }
    }
#endif

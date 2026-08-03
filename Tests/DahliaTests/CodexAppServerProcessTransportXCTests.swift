import Darwin
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexAppServerProcessTransportTests {
        @Test
        func outputRelayPreservesOneThousandCallbackFragmentsInOrder() async {
            let relay = CodexOutputReadRelay()
            let fragments = (0 ..< 1000).map { Data(String(format: "%04d,", $0).utf8) }

            for (index, fragment) in fragments.enumerated() {
                relay.append(fragment, done: index == fragments.count - 1, errorCode: 0)
            }

            let snapshot = await relay.next()
            let expectedData = fragments.reduce(into: Data()) { $0.append($1) }
            #expect(snapshot.data == expectedData)
            #expect(snapshot.totalByteCount == expectedData.count)
            #expect(snapshot.terminalErrorCode == 0)
        }

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
        func abnormalProcessExitIncludesStderrTail() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'codex panic detail' >&2; exit 7"]
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
        func delayedActorDrainPreservesOneThousandDeltaLinesWithinOneReadWindow() async throws {
            let gate = CodexAppServerOutputReadTestGate()
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "i=0; while [ $i -lt 1000 ]; do "
                        + "printf '{\"method\":\"delta\",\"params\":{\"index\":%04d,\"delta\":\"xxxxxxxx\"}}\\n' $i; "
                        + "i=$((i+1)); done",
                ]
            )
            await transport.setOutputReadTestGateForTesting(gate)

            let firstLine = Task { try await transport.receiveLine() }
            let retainedByteCount = await gate.waitUntilReadFinished()
            #expect(retainedByteCount > 0)
            #expect(retainedByteCount <= 64 * 1024)
            gate.resumeDraining()

            let expectedLines = (0 ..< 1000).map {
                Data(String(format: "{\"method\":\"delta\",\"params\":{\"index\":%04d,\"delta\":\"xxxxxxxx\"}}", $0).utf8)
            }
            let receivedFirstLine = try #require(await firstLine.value)
            var receivedLines = [receivedFirstLine]
            for _ in 1 ..< expectedLines.count {
                try receivedLines.append(#require(await transport.receiveLine()))
            }
            #expect(receivedLines == expectedLines)
            await transport.close()
        }

        @Test
        func burstBeyondFormerLineLimitDrainsInFIFOOrder() async throws {
            let payload = String(repeating: "x", count: 64)
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "i=0; while [ $i -lt 2048 ]; do printf '%04d:\(payload)\\n' $i; i=$((i+1)); done",
                ]
            )
            let expectedLines = (0 ..< 2048).map {
                Data((String(format: "%04d:", $0) + payload).utf8)
            }

            var receivedLines: [Data] = []
            for _ in expectedLines.indices {
                try receivedLines.append(#require(await transport.receiveLine()))
            }
            #expect(receivedLines == expectedLines)
            await transport.close()
        }

        @Test
        func lineCanCrossSixtyFourKiBReadBoundary() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "dd if=/dev/zero bs=65536 count=1 2>/dev/null | tr '\\000' a; printf 'b\\n'"]
            )

            var expectedLine = Data(repeating: 0x61, count: 64 * 1024)
            expectedLine.append(0x62)
            #expect(try await transport.receiveLine() == expectedLine)
            await transport.close()
        }

        @Test
        func eofDeliversTrailingLineWithoutNewline() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf trailing"]
            )

            #expect(try await transport.receiveLine() == Data("trailing".utf8))
            await transport.close()
        }

        @Test
        func lineAtFourMiBLimitIsAccepted() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "dd if=/dev/zero bs=1048576 count=4 2>/dev/null | tr '\\000' a; printf '\\n'",
                ]
            )

            let line = try #require(await transport.receiveLine())
            #expect(line.count == 4 * 1024 * 1024)
            #expect(line.first == 0x61)
            #expect(line.last == 0x61)
            await transport.close()
        }

        @Test
        func sentLineAllowsLargerWrappedEcho() async throws {
            let baseMaximumOutputLineBytes = 64
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "IFS= read -r line; printf '{\"echo\":\"%s\"}\\n' \"$line\"",
                ],
                baseMaximumOutputLineBytes: baseMaximumOutputLineBytes
            )
            let sentLine = Data(repeating: 0x61, count: baseMaximumOutputLineBytes + 1)

            try await transport.sendLine(sentLine)
            let response = try #require(await transport.receiveLine())
            #expect(response.count > sentLine.count)
            #expect(response.starts(with: Data(#"{"echo":""#.utf8)))
            #expect(response.suffix(2) == Data(#""}"#.utf8))
            await transport.close()
        }

        @Test
        func lineBeyondFourMiBLimitFailsClosed() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "{ dd if=/dev/zero bs=1048576 count=4 2>/dev/null; printf '\\000'; } | tr '\\000' a",
                ]
            )

            await #expect(throws: CodexAppServerError.outputLineTooLarge) {
                _ = try await transport.receiveLine()
            }
            await transport.close()
        }

        @Test
        func lineBeyondSentLineAllowanceFailsClosed() async throws {
            let baseMaximumOutputLineBytes = 64
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "head -c 8 >/dev/null; "
                        + "dd if=/dev/zero bs=72 count=1 2>/dev/null",
                ],
                baseMaximumOutputLineBytes: baseMaximumOutputLineBytes
            )

            try await transport.sendLine(Data("request".utf8))
            await #expect(throws: CodexAppServerError.outputLineTooLarge) {
                _ = try await transport.receiveLine()
            }
            await transport.close()
        }

        @Test
        func receiveLineAfterCloseReportsClosureInsteadOfReadingATornDownDescriptor() async throws {
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: []
            )

            try await transport.sendLine(Data("first".utf8))
            #expect(try await transport.receiveLine() == Data("first".utf8))
            await transport.close()

            // The shared service reader loop can re-enter receiveLine after a concurrent shutdown.
            #expect(try await transport.receiveLine() == nil)
            #expect(try await transport.receiveLine() == nil)
        }

        @Test
        func closeImmediatelyAfterStartingTheDrainDoesNotTearDownAnActiveRead() async throws {
            let gate = CodexAppServerOutputReadTestGate()
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                arguments: []
            )
            await transport.setOutputReadTestGateForTesting(gate)

            let pending = Task { try await transport.receiveLine() }
            await gate.waitUntilReadStarted()
            gate.resumeDraining()
            await transport.close()

            #expect(try await pending.value == nil)
        }
    }
#endif

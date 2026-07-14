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
                arguments: ["-c", "i=0; while [ $i -lt 400 ]; do printf '%s\\n' $i; i=$((i+1)); done"]
            )

            _ = try await transport.receiveLine()
            try await Task.sleep(for: .milliseconds(100))
            #expect(await transport.bufferedOutputLineCountForTesting() <= 256)
            await transport.close()
        }
    }
#endif

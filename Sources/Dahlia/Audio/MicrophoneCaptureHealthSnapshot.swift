import Foundation

struct MicrophoneCaptureHealthSnapshot: Equatable, Sendable {
    let captureID: UUID
    let elapsed: Duration
    let intervalBufferCount: Int
    let totalBufferCount: Int
    let totalFrameCount: Int64
    let lastLevel: Double?
    let lastBufferAge: Duration?

    var diagnosticDescription: String {
        var components = [
            "elapsedSeconds=\(elapsed.seconds.formatted(.number.precision(.fractionLength(3))))",
            "intervalBuffers=\(intervalBufferCount)",
            "totalBuffers=\(totalBufferCount)",
            "totalFrames=\(totalFrameCount)",
        ]
        if let lastLevel {
            components.append("lastLevel=\(lastLevel.formatted(.number.precision(.fractionLength(4))))")
        }
        if let lastBufferAge {
            components.append(
                "lastBufferAgeSeconds=\(lastBufferAge.seconds.formatted(.number.precision(.fractionLength(3))))"
            )
        }
        return components.joined(separator: " ")
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

@preconcurrency import AVFoundation
import CoreMedia
import os
import Speech
@testable import Dahlia

final class FakeAnalyzerInputConverter: AnalyzerInputConverting {
    private let outputFormat: AVAudioFormat
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var conversionCount: Int {
        count.withLock { $0 }
    }

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_: AVAudioPCMBuffer, at startTime: CMTime) throws -> [AnalyzerInput] {
        count.withLock { $0 += 1 }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1) else {
            return []
        }
        buffer.frameLength = 1
        return [AnalyzerInput(buffer: buffer, bufferStartTime: startTime)]
    }

    func finish() throws -> [AnalyzerInput] {
        []
    }
}

import CoreGraphics
import Foundation

#if canImport(Testing)
    actor ControlledImageDecoder {
        let image: CGImage?
        private(set) var callCount = 0
        private(set) var isWaiting = false
        private var isBlocked: Bool
        private var decodeWaiters: [CheckedContinuation<Void, Never>] = []
        private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        init(image: CGImage?, startsBlocked: Bool = false) {
            self.image = image
            self.isBlocked = startsBlocked
        }

        func decode(_: Data, _: Int) async -> CGImage? {
            callCount += 1
            let satisfied = callWaiters.filter { callCount >= $0.count }
            callWaiters.removeAll { callCount >= $0.count }
            satisfied.forEach { $0.continuation.resume() }
            if isBlocked {
                isWaiting = true
                await withCheckedContinuation { continuation in
                    decodeWaiters.append(continuation)
                }
                isWaiting = false
            }
            return image
        }

        func waitForCallCount(_ count: Int) async {
            guard callCount < count else { return }
            await withCheckedContinuation { continuation in
                callWaiters.append((count, continuation))
            }
        }

        func resume() {
            isBlocked = false
            let waiters = decodeWaiters
            decodeWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    actor SourceAwareImageDecoder {
        let images: [Data: CGImage]
        private(set) var callCount = 0

        init(images: [Data: CGImage]) {
            self.images = images
        }

        func decode(_ data: Data, _: Int) async -> CGImage? {
            callCount += 1
            return images[data]
        }
    }

    actor ReplacingImageDecoder {
        let blockedData: Data
        let blockedImage: CGImage
        let replacementImage: CGImage
        private(set) var callCount = 0
        private var blockedDecodeStarted = false
        private var blockedDecodeContinuation: CheckedContinuation<Void, Never>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            blockedData: Data,
            blockedImage: CGImage,
            replacementImage: CGImage
        ) {
            self.blockedData = blockedData
            self.blockedImage = blockedImage
            self.replacementImage = replacementImage
        }

        func decode(_ data: Data, _: Int) async -> CGImage? {
            callCount += 1
            guard data == blockedData else { return replacementImage }
            blockedDecodeStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                blockedDecodeContinuation = continuation
            }
            return blockedImage
        }

        func waitUntilBlockedDecodeStarts() async {
            guard !blockedDecodeStarted else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func resumeBlockedDecode() {
            blockedDecodeContinuation?.resume()
            blockedDecodeContinuation = nil
        }
    }
#endif

import CoreGraphics
import DahliaRuntimeSupport
import Foundation
import Observation

/// サムネイルキャッシュを所有し、用途別のデコードレーンへ処理を振り分ける。
actor ScreenshotImageLoader {
    typealias Decoder = @Sendable (Data, Int) async -> CGImage?

    static let shared = ScreenshotImageLoader()

    private struct CacheKey: Hashable {
        let screenshotID: UUID
        let maxPixelSize: Int
    }

    private struct CacheEntry {
        let image: CGImage
        let sourceData: Data
        let cost: Int
        var lastAccess: UInt64
    }

    private struct InFlightDecode {
        let id: UInt64
        let sourceData: Data
        var decodeTask: Task<Void, Never>?
        var waiters: [UInt64: CheckedContinuation<CGImage?, Never>] = [:]
    }

    private let cacheCostLimit: Int
    private let cacheableDecoder: Decoder
    private nonisolated let interactiveDecoder: Decoder
    private var cache: [CacheKey: CacheEntry] = [:]
    private var inFlightDecodes: [CacheKey: InFlightDecode] = [:]
    private var cacheCost = 0
    private var accessCounter: UInt64 = 0
    private var nextDecodeID: UInt64 = 0
    private var nextWaiterID: UInt64 = 0

    init(
        cacheCostLimit: Int = 32 * 1024 * 1024,
        cacheableDecoder: Decoder? = nil,
        interactiveDecoder: Decoder? = nil
    ) {
        self.cacheCostLimit = cacheCostLimit
        self.cacheableDecoder = cacheableDecoder ?? Self.makeDefaultDecoder(lane: .cacheable)
        self.interactiveDecoder = interactiveDecoder ?? Self.makeDefaultDecoder(lane: .interactive)
    }

    func image(screenshotID: UUID, data: Data, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled, maxPixelSize > 0 else { return nil }

        let key = CacheKey(screenshotID: screenshotID, maxPixelSize: maxPixelSize)
        if var entry = cache[key] {
            if entry.sourceData == data {
                accessCounter &+= 1
                entry.lastAccess = accessCounter
                cache[key] = entry
                return entry.image
            }
            cache[key] = nil
            cacheCost -= entry.cost
        }

        if let decode = inFlightDecodes[key] {
            if decode.sourceData == data {
                return await waitForDecode(key: key, decodeID: decode.id)
            }
            invalidateDecode(for: key)
        }

        nextDecodeID &+= 1
        let decode = InFlightDecode(id: nextDecodeID, sourceData: data)
        inFlightDecodes[key] = decode
        let decodeTask = Task { [cacheableDecoder] in
            let image = await cacheableDecoder(data, maxPixelSize)
            self.finishDecode(image, key: key, id: decode.id)
        }
        inFlightDecodes[key]?.decodeTask = decodeTask
        return await waitForDecode(key: key, decodeID: decode.id)
    }

    /// User-initiated detail decode. This lane never reads or writes the shared image cache.
    nonisolated func transientImage(data: Data, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled, maxPixelSize > 0 else { return nil }
        return await interactiveDecoder(data, maxPixelSize)
    }

    func cacheEntryCount() -> Int {
        cache.count
    }

    func inFlightCacheableRequestCount() -> Int {
        inFlightDecodes.values.reduce(0) { $0 + $1.waiters.count }
    }

    func remove(screenshotID: UUID) {
        let activeKeys = inFlightDecodes.keys.filter { $0.screenshotID == screenshotID }
        for key in activeKeys {
            invalidateDecode(for: key)
        }
        let keys = cache.keys.filter { $0.screenshotID == screenshotID }
        for key in keys {
            if let removed = cache.removeValue(forKey: key) {
                cacheCost -= removed.cost
            }
        }
    }

    private func waitForDecode(key: CacheKey, decodeID: UInt64) async -> CGImage? {
        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        return await withTaskCancellationHandler {
            let image: CGImage? = await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      var decode = inFlightDecodes[key],
                      decode.id == decodeID else {
                    continuation.resume(returning: nil)
                    return
                }
                decode.waiters[waiterID] = continuation
                inFlightDecodes[key] = decode
            }
            return Task.isCancelled ? nil : image
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    key: key,
                    decodeID: decodeID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func finishDecode(_ image: CGImage?, key: CacheKey, id: UInt64) {
        guard let decode = inFlightDecodes[key], decode.id == id else { return }
        inFlightDecodes[key] = nil

        if let image {
            accessCounter &+= 1
            let cost = image.bytesPerRow * image.height + decode.sourceData.count
            cache[key] = CacheEntry(
                image: image,
                sourceData: decode.sourceData,
                cost: cost,
                lastAccess: accessCounter
            )
            cacheCost += cost
            evictIfNeeded(excluding: key)
        }
        decode.waiters.values.forEach { $0.resume(returning: image) }
    }

    private func invalidateDecode(for key: CacheKey) {
        guard let decode = inFlightDecodes.removeValue(forKey: key) else { return }
        decode.decodeTask?.cancel()
        decode.waiters.values.forEach { $0.resume(returning: nil) }
    }

    private func cancelWaiter(
        key: CacheKey,
        decodeID: UInt64,
        waiterID: UInt64
    ) {
        guard var decode = inFlightDecodes[key],
              decode.id == decodeID,
              let continuation = decode.waiters.removeValue(forKey: waiterID) else { return }
        if decode.waiters.isEmpty {
            inFlightDecodes[key] = nil
            decode.decodeTask?.cancel()
        } else {
            inFlightDecodes[key] = decode
        }
        continuation.resume(returning: nil)
    }

    private static func makeDefaultDecoder(lane: ScreenshotImageDecodeWorker.Lane) -> Decoder {
        let worker = ScreenshotImageDecodeWorker(lane: lane)
        return { data, maxPixelSize in
            await worker.decode(
                data,
                maxPixelSize: maxPixelSize,
                requestedAt: .now
            )
        }
    }

    private func evictIfNeeded(excluding protectedKey: CacheKey) {
        while cacheCost > cacheCostLimit,
              let oldest = cache
              .filter({ $0.key != protectedKey })
              .min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            cache.removeValue(forKey: oldest.key)
            cacheCost -= oldest.value.cost
        }
    }
}

@MainActor
@Observable
final class ScreenshotImageLoadModel {
    enum State {
        case idle
        case loading
        case loaded(CGImage)
        case failed
    }

    private(set) var state: State = .idle
    private let loader: ScreenshotImageLoader
    private var loadGeneration: UInt64 = 0

    init(loader: ScreenshotImageLoader = .shared) {
        self.loader = loader
    }

    func load(screenshotID: UUID, data: Data, maxPixelSize: Int) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        let image = await loader.image(
            screenshotID: screenshotID,
            data: data,
            maxPixelSize: maxPixelSize
        )
        guard !Task.isCancelled, loadGeneration == generation else { return }
        state = image.map(State.loaded) ?? .failed
    }

    func loadTransient(
        data: Data,
        maxPixelSize: Int,
        requestedAt: ContinuousClock.Instant
    ) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        let image = await loader.transientImage(
            data: data,
            maxPixelSize: maxPixelSize
        )
        guard !Task.isCancelled, loadGeneration == generation else { return }
        state = image.map(State.loaded) ?? .failed
        if image != nil {
            ScreenshotImageDecodeWorker.recordInteractiveImageApplied(requestedAt: requestedAt)
        }
    }

    /// 画面外になった表示要素からデコード済み画像を解放する。
    func unload() {
        loadGeneration &+= 1
        state = .idle
    }
}

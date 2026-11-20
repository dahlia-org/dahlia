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
        /// Changes with the image content, so a hit needs no read of the original. nil when the caller only has bytes.
        let contentHash: String?
        let maxPixelSize: Int
    }

    private struct CacheEntry {
        let image: CGImage
        let sourceData: Data
        let cost: Int
        var lastAccess: UInt64
    }

    /// Encoded thumbnails, tens of kilobytes each, so the cache holds a whole grid where decoded images would hold
    /// about sixty. A hit decodes again in well under a millisecond.
    private struct EncodedEntry {
        let bytes: Data
        var lastAccess: UInt64
    }

    private struct InFlightDecode {
        let id: UInt64
        let sourceData: Data
        var decodeTask: Task<Void, Never>?
        var waiters: [UInt64: CheckedContinuation<CGImage?, Never>] = [:]
    }

    private let cacheCostLimit: Int
    private let contentProvider: ScreenshotContentProvider
    private let cacheableDecoder: Decoder
    private nonisolated let interactiveDecoder: Decoder
    private var cache: [CacheKey: CacheEntry] = [:]
    private var encodedCache: [CacheKey: EncodedEntry] = [:]
    private var encodedCacheCost = 0
    private var inFlightDecodes: [CacheKey: InFlightDecode] = [:]
    private var cacheCost = 0
    private var accessCounter: UInt64 = 0
    private var nextDecodeID: UInt64 = 0
    private var nextWaiterID: UInt64 = 0

    init(
        cacheCostLimit: Int = 32 * 1024 * 1024,
        contentProvider: ScreenshotContentProvider = .shared,
        cacheableDecoder: Decoder? = nil,
        interactiveDecoder: Decoder? = nil
    ) {
        self.cacheCostLimit = cacheCostLimit
        self.contentProvider = contentProvider
        self.cacheableDecoder = cacheableDecoder ?? Self.makeDefaultDecoder(lane: .cacheable)
        self.interactiveDecoder = interactiveDecoder ?? Self.makeDefaultDecoder(lane: .interactive)
    }

    func image(screenshotID: UUID, contentHash: String? = nil, data: Data?, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled, maxPixelSize > 0 else { return nil }
        let key = CacheKey(screenshotID: screenshotID, contentHash: contentHash, maxPixelSize: maxPixelSize)
        if contentHash != nil {
            return await encodedImage(key: key, data: data)
        }

        let bytes: Data
        if let data {
            bytes = data
        } else {
            guard let content = try? await contentProvider.content(
                id: screenshotID, variant: maxPixelSize <= ScreenshotGridSizing.maximumThumbnailPixelSize ? .thumbnail : .original
            ) else { return nil }
            bytes = content.data
        }
        if var entry = cache[key] {
            if entry.sourceData == bytes {
                accessCounter &+= 1
                entry.lastAccess = accessCounter
                cache[key] = entry
                return entry.image
            }
            cache[key] = nil
            cacheCost -= entry.cost
        }

        if let decode = inFlightDecodes[key] {
            if decode.sourceData == bytes {
                return await waitForDecode(key: key, decodeID: decode.id)
            }
            invalidateDecode(for: key)
        }

        nextDecodeID &+= 1
        let decode = InFlightDecode(id: nextDecodeID, sourceData: bytes)
        inFlightDecodes[key] = decode
        let decodeTask = Task { [cacheableDecoder] in
            let image = await cacheableDecoder(bytes, maxPixelSize)
            self.finishDecode(image, key: key, id: decode.id)
        }
        inFlightDecodes[key]?.decodeTask = decodeTask
        return await waitForDecode(key: key, decodeID: decode.id)
    }

    /// A hit in the encoded cache, decoded; nil without reading anything when the image is not cached.
    func cachedImage(screenshotID: UUID, contentHash: String, maxPixelSize: Int) async -> CGImage? {
        let key = CacheKey(screenshotID: screenshotID, contentHash: contentHash, maxPixelSize: maxPixelSize)
        guard encodedCache[key] != nil else { return nil }
        return await encodedImage(key: key, data: nil)
    }

    /// A content-hashed request: the key names the content, so the cache keeps the encoded bytes and decodes on each hit.
    private func encodedImage(key: CacheKey, data: Data?) async -> CGImage? {
        let bytes: Data
        if var entry = encodedCache[key] {
            accessCounter &+= 1
            entry.lastAccess = accessCounter
            encodedCache[key] = entry
            bytes = entry.bytes
        } else {
            if let data {
                bytes = data
            } else {
                let variant: ScreenshotVariant = key.maxPixelSize <= ScreenshotGridSizing.maximumThumbnailPixelSize ? .thumbnail : .original
                guard let content = try? await contentProvider.content(id: key.screenshotID, variant: variant) else { return nil }
                bytes = content.data
            }
            accessCounter &+= 1
            if let replaced = encodedCache.updateValue(EncodedEntry(bytes: bytes, lastAccess: accessCounter), forKey: key) {
                encodedCacheCost -= replaced.bytes.count
            }
            encodedCacheCost += bytes.count
            while encodedCacheCost > cacheCostLimit,
                  let oldest = encodedCache.filter({ $0.key != key }).min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
                encodedCache[oldest.key] = nil
                encodedCacheCost -= oldest.value.bytes.count
            }
        }
        guard !Task.isCancelled else { return nil }
        return await cacheableDecoder(bytes, key.maxPixelSize)
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
        for key in encodedCache.keys where key.screenshotID == screenshotID {
            encodedCacheCost -= encodedCache.removeValue(forKey: key)?.bytes.count ?? 0
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

    func load(screenshotID: UUID, data: Data?, maxPixelSize: Int) async {
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

    /// Cache hits skip image I/O, while the caller validates the current scope and content source on every load.
    func load(
        screenshotID: UUID,
        contentHash: String,
        maxPixelSize: Int,
        isAvailable: () async -> Bool,
        data: () async -> Data?
    ) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        var image = await loader.cachedImage(screenshotID: screenshotID, contentHash: contentHash, maxPixelSize: maxPixelSize)
        if image == nil, !Task.isCancelled, loadGeneration == generation, let bytes = await data() {
            image = await loader.image(screenshotID: screenshotID, contentHash: contentHash, data: bytes, maxPixelSize: maxPixelSize)
        }
        guard !Task.isCancelled, loadGeneration == generation else { return }
        // Revalidate after decoding as well: deletion or an account change can happen during that work.
        let available = await isAvailable()
        guard !Task.isCancelled, loadGeneration == generation else { return }
        state = available ? image.map(State.loaded) ?? .failed : .failed
    }

    func loadTransient(
        screenshotID: UUID? = nil,
        data: Data?,
        maxPixelSize: Int,
        requestedAt: ContinuousClock.Instant
    ) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        state = .loading
        var bytes = data
        if bytes == nil, let screenshotID {
            bytes = try? await ScreenshotContentProvider.shared.content(id: screenshotID).data
        }
        guard !Task.isCancelled, loadGeneration == generation else { return }
        guard let bytes else { state = .failed
            return
        }
        let image = await loader.transientImage(
            data: bytes,
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

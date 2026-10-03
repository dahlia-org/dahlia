import CoreGraphics
import Foundation
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct ScreenshotImageLoaderTests {
        @Test
        func downsampledImageRespectsPixelLimit() async throws {
            let image = try #require(makeImage(width: 200, height: 100))
            let data = try #require(ImageEncoder.encode(image, quality: 0.8))
            let loader = ScreenshotImageLoader(cacheCostLimit: 1024 * 1024)

            let decoded = await loader.image(
                screenshotID: UUID.v7(),
                data: data,
                maxPixelSize: 64
            )

            let result = try #require(decoded)
            #expect(max(result.width, result.height) <= 64)
        }

        @Test
        func invalidImageDataFailsWithoutBlockingFutureLoads() async throws {
            let loader = ScreenshotImageLoader(cacheCostLimit: 1024 * 1024)
            let invalid = await loader.image(
                screenshotID: UUID.v7(),
                data: Data("not an image".utf8),
                maxPixelSize: 64
            )
            #expect(invalid == nil)

            let image = try #require(makeImage(width: 32, height: 32))
            let data = try #require(ImageEncoder.encode(image, quality: 0.8))
            let valid = await loader.image(
                screenshotID: UUID.v7(),
                data: data,
                maxPixelSize: 64
            )
            #expect(valid != nil)
        }

        @Test
        func unloadingReleasesLoadedImageState() async throws {
            let image = try #require(makeImage(width: 32, height: 32))
            let data = try #require(ImageEncoder.encode(image, quality: 0.8))
            let model = ScreenshotImageLoadModel()

            await model.load(
                screenshotID: UUID.v7(),
                data: data,
                maxPixelSize: 32
            )
            guard case .loaded = model.state else {
                Issue.record("Expected the image to finish loading")
                return
            }

            model.unload()

            guard case .idle = model.state else {
                Issue.record("Expected unload to release the loaded image")
                return
            }
        }

        @Test
        func interactiveDecodeDoesNotWaitBehindBlockedCacheableDecode() async throws {
            let thumbnail = try #require(makeImage(width: 32, height: 18))
            let detail = try #require(makeImage(width: 96, height: 54))
            let cacheableDecoder = ControlledImageDecoder(image: thumbnail, startsBlocked: true)
            let interactiveDecoder = ControlledImageDecoder(image: detail)
            let loader = ScreenshotImageLoader(
                cacheCostLimit: 1024 * 1024,
                cacheableDecoder: cacheableDecoder.decode,
                interactiveDecoder: interactiveDecoder.decode
            )

            let cacheableTask = Task {
                await loader.image(
                    screenshotID: UUID.v7(),
                    data: Data([1]),
                    maxPixelSize: 64
                )
            }
            await cacheableDecoder.waitForCallCount(1)

            let decodedDetail = await loader.transientImage(
                data: Data([2]),
                maxPixelSize: 2400
            )

            #expect(decodedDetail?.width == 96)
            #expect(await interactiveDecoder.callCount == 1)
            #expect(await cacheableDecoder.isWaiting)

            await cacheableDecoder.resume()
            _ = await cacheableTask.value
        }

        @Test
        func transientImagesAreDecodedEveryTimeAndNeverCached() async throws {
            let detail = try #require(makeImage(width: 96, height: 54))
            let decoder = ControlledImageDecoder(image: detail)
            let loader = ScreenshotImageLoader(
                cacheCostLimit: 1024 * 1024,
                interactiveDecoder: decoder.decode
            )

            _ = await loader.transientImage(data: Data([1]), maxPixelSize: 2400)
            _ = await loader.transientImage(data: Data([1]), maxPixelSize: 2400)

            #expect(await decoder.callCount == 2)
            #expect(await loader.cacheEntryCount() == 0)
        }

        @Test
        func cacheableImagesStillReuseDecodedResult() async throws {
            let thumbnail = try #require(makeImage(width: 32, height: 18))
            let decoder = ControlledImageDecoder(image: thumbnail)
            let loader = ScreenshotImageLoader(
                cacheCostLimit: 1024 * 1024,
                cacheableDecoder: decoder.decode
            )
            let screenshotID = UUID.v7()

            _ = await loader.image(
                screenshotID: screenshotID,
                data: Data([1]),
                maxPixelSize: 64
            )
            _ = await loader.image(
                screenshotID: screenshotID,
                data: Data([1]),
                maxPixelSize: 64
            )

            #expect(await decoder.callCount == 1)
            #expect(await loader.cacheEntryCount() == 1)
        }
    }

    extension ScreenshotImageLoaderTests {
        @Test
        func changedSourceDataReplacesCachedImageForTheSameIdentifier() async throws {
            let originalImage = try #require(makeImage(width: 32, height: 18))
            let replacementImage = try #require(makeImage(width: 40, height: 20))
            let decoder = SourceAwareImageDecoder(
                images: [
                    Data([1]): originalImage,
                    Data([2]): replacementImage,
                ]
            )
            let loader = ScreenshotImageLoader(
                cacheCostLimit: 1024 * 1024,
                cacheableDecoder: decoder.decode
            )
            let screenshotID = UUID.v7()

            let original = await loader.image(
                screenshotID: screenshotID,
                data: Data([1]),
                maxPixelSize: 64
            )
            let replacement = await loader.image(
                screenshotID: screenshotID,
                data: Data([2]),
                maxPixelSize: 64
            )

            #expect(original?.width == 32)
            #expect(replacement?.width == 40)
            #expect(await decoder.callCount == 2)
            #expect(await loader.cacheEntryCount() == 1)
        }

        @Test
        func changedSourceDataInvalidatesAnOlderInFlightDecode() async throws {
            let originalImage = try #require(makeImage(width: 32, height: 18))
            let replacementImage = try #require(makeImage(width: 40, height: 20))
            let originalData = Data([1])
            let replacementData = Data([2])
            let decoder = ReplacingImageDecoder(
                blockedData: originalData,
                blockedImage: originalImage,
                replacementImage: replacementImage
            )
            let loader = ScreenshotImageLoader(
                cacheCostLimit: 1024 * 1024,
                cacheableDecoder: decoder.decode
            )
            let screenshotID = UUID.v7()

            let originalTask = Task {
                await loader.image(
                    screenshotID: screenshotID,
                    data: originalData,
                    maxPixelSize: 64
                )
            }
            await decoder.waitUntilBlockedDecodeStarts()

            let replacement = await loader.image(
                screenshotID: screenshotID,
                data: replacementData,
                maxPixelSize: 64
            )

            #expect(replacement?.width == 40)
            #expect(await decoder.callCount == 2)
            await decoder.resumeBlockedDecode()
            #expect(await originalTask.value == nil)

            let cachedReplacement = await loader.image(
                screenshotID: screenshotID,
                data: replacementData,
                maxPixelSize: 64
            )
            #expect(cachedReplacement?.width == 40)
            #expect(await decoder.callCount == 2)
            #expect(await loader.cacheEntryCount() == 1)
        }

        @Test
        func concurrentCacheableRequestsShareOneDecode() async throws {
            let thumbnail = try #require(makeImage(width: 32, height: 18))
            let decoder = ControlledImageDecoder(image: thumbnail, startsBlocked: true)
            let entryCost = thumbnail.bytesPerRow * thumbnail.height + 1
            let loader = ScreenshotImageLoader(
                cacheCostLimit: entryCost * 2,
                cacheableDecoder: decoder.decode
            )
            let screenshotID = UUID.v7()

            let first = Task {
                await loader.image(
                    screenshotID: screenshotID,
                    data: Data([1]),
                    maxPixelSize: 64
                )
            }
            await decoder.waitForCallCount(1)
            let second = Task {
                await loader.image(
                    screenshotID: screenshotID,
                    data: Data([1]),
                    maxPixelSize: 64
                )
            }
            #expect(await waitUntil {
                await loader.inFlightCacheableRequestCount() == 2
            })

            #expect(await decoder.callCount == 1)
            await decoder.resume()
            #expect(await first.value != nil)
            #expect(await second.value != nil)
            #expect(await decoder.callCount == 1)
            #expect(await loader.cacheEntryCount() == 1)

            _ = await loader.image(
                screenshotID: UUID.v7(),
                data: Data([2]),
                maxPixelSize: 64
            )
            #expect(await decoder.callCount == 2)
            #expect(await loader.cacheEntryCount() == 2)
        }

        @Test
        func cancellingAJoinedRequestRemovesItsWaiterImmediately() async throws {
            let thumbnail = try #require(makeImage(width: 32, height: 18))
            let decoder = ControlledImageDecoder(image: thumbnail, startsBlocked: true)
            let loader = ScreenshotImageLoader(
                cacheCostLimit: 1024 * 1024,
                cacheableDecoder: decoder.decode
            )
            let screenshotID = UUID.v7()
            let leader = Task {
                await loader.image(
                    screenshotID: screenshotID,
                    data: Data([1]),
                    maxPixelSize: 64
                )
            }
            await decoder.waitForCallCount(1)
            let follower = Task {
                await loader.image(
                    screenshotID: screenshotID,
                    data: Data([1]),
                    maxPixelSize: 64
                )
            }
            #expect(await waitUntil {
                await loader.inFlightCacheableRequestCount() == 2
            })

            follower.cancel()

            #expect(await follower.value == nil)
            #expect(await waitUntil {
                await loader.inFlightCacheableRequestCount() == 1
            })
            #expect(await decoder.isWaiting)

            await decoder.resume()
            #expect(await leader.value != nil)
        }

        @Test
        func cancellingTheLeadingRequestKeepsTheSharedDecodeForRemainingWaiters() async throws {
            let thumbnail = try #require(makeImage(width: 32, height: 18))
            let decoder = ControlledImageDecoder(image: thumbnail, startsBlocked: true)
            let loader = ScreenshotImageLoader(
                cacheCostLimit: 1024 * 1024,
                cacheableDecoder: decoder.decode
            )
            let screenshotID = UUID.v7()
            let leader = Task {
                await loader.image(
                    screenshotID: screenshotID,
                    data: Data([1]),
                    maxPixelSize: 64
                )
            }
            await decoder.waitForCallCount(1)
            let follower = Task {
                await loader.image(
                    screenshotID: screenshotID,
                    data: Data([1]),
                    maxPixelSize: 64
                )
            }
            #expect(await waitUntil {
                await loader.inFlightCacheableRequestCount() == 2
            })

            leader.cancel()

            #expect(await leader.value == nil)
            #expect(await waitUntil {
                await loader.inFlightCacheableRequestCount() == 1
            })
            #expect(await decoder.isWaiting)

            await decoder.resume()
            #expect(await follower.value != nil)
            #expect(await loader.cacheEntryCount() == 1)
        }

        @Test
        func removalDuringDecodePreventsCacheReinsertion() async throws {
            let thumbnail = try #require(makeImage(width: 32, height: 18))
            let decoder = ControlledImageDecoder(image: thumbnail, startsBlocked: true)
            let loader = ScreenshotImageLoader(
                cacheCostLimit: 1024 * 1024,
                cacheableDecoder: decoder.decode
            )
            let screenshotID = UUID.v7()

            let load = Task {
                await loader.image(
                    screenshotID: screenshotID,
                    data: Data([1]),
                    maxPixelSize: 64
                )
            }
            await decoder.waitForCallCount(1)
            let follower = Task {
                await loader.image(
                    screenshotID: screenshotID,
                    data: Data([1]),
                    maxPixelSize: 64
                )
            }
            #expect(await waitUntil {
                await loader.inFlightCacheableRequestCount() == 2
            })
            await loader.remove(screenshotID: screenshotID)

            #expect(await follower.value == nil)
            await decoder.resume()

            #expect(await load.value == nil)
            #expect(await loader.cacheEntryCount() == 0)
        }

        @Test
        func unloadingTransientModelRejectsLateDecodeResult() async throws {
            let detail = try #require(makeImage(width: 96, height: 54))
            let decoder = ControlledImageDecoder(image: detail, startsBlocked: true)
            let loader = ScreenshotImageLoader(
                cacheCostLimit: 1024 * 1024,
                interactiveDecoder: decoder.decode
            )
            let model = ScreenshotImageLoadModel(loader: loader)
            let loadTask = Task { @MainActor in
                await model.loadTransient(
                    data: Data([1]),
                    maxPixelSize: 2400,
                    requestedAt: .now
                )
            }
            await decoder.waitForCallCount(1)

            model.unload()
            await decoder.resume()
            await loadTask.value

            guard case .idle = model.state else {
                Issue.record("A dismissed overlay must reject its late decode result")
                return
            }
        }

        private func makeImage(width: Int, height: Int) -> CGImage? {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }

        private func waitUntil(
            _ condition: @escaping @Sendable () async -> Bool
        ) async -> Bool {
            await pollUntil { await condition() }
        }
    }
#endif

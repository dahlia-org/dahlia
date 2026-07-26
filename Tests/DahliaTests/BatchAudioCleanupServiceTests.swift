import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchAudioCleanupServiceTests {
        @Test
        func discardSurfacesFailureAndAttemptsEveryStagedFile() {
            let firstURL = URL(fileURLWithPath: "/tmp/first-staged-audio")
            let secondURL = URL(fileURLWithPath: "/tmp/second-staged-audio")
            let stagedFiles = [
                BatchAudioCleanupService.StagedFile(originalURL: firstURL, stagedURL: firstURL),
                BatchAudioCleanupService.StagedFile(originalURL: secondURL, stagedURL: secondURL),
            ]
            let expectedError = CocoaError(.fileWriteNoPermission)
            var attemptedURLs: [URL] = []

            do {
                try BatchAudioCleanupService.discardStagedFiles(stagedFiles) { url in
                    attemptedURLs.append(url)
                    if url == firstURL {
                        throw expectedError
                    }
                }
                Issue.record("Expected staged audio cleanup to fail")
            } catch let error as CocoaError {
                #expect(error.code == expectedError.code)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(attemptedURLs == [firstURL, secondURL])
        }

        @Test
        func restoreSurfacesFailureAndAttemptsEveryStagedFile() {
            let firstURL = URL(fileURLWithPath: "/tmp/first-staged-audio")
            let secondURL = URL(fileURLWithPath: "/tmp/second-staged-audio")
            let stagedFiles = [
                BatchAudioCleanupService.StagedFile(originalURL: firstURL, stagedURL: firstURL),
                BatchAudioCleanupService.StagedFile(originalURL: secondURL, stagedURL: secondURL),
            ]
            let expectedError = CocoaError(.fileWriteNoPermission)
            var attemptedURLs: [URL] = []

            do {
                try BatchAudioCleanupService.restoreStagedFiles(
                    stagedFiles,
                    fileExists: { _ in true },
                    moveItem: { stagedURL, _ in
                        attemptedURLs.append(stagedURL)
                        if stagedURL == secondURL {
                            throw expectedError
                        }
                    }
                )
                Issue.record("Expected staged audio restore to fail")
            } catch let error as CocoaError {
                #expect(error.code == expectedError.code)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(attemptedURLs == [secondURL, firstURL])
        }
    }
#endif

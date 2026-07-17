import AVFoundation
import CoreAudio
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AudioCaptureManagerTests {
        @Test
        func voiceProcessingFallsBackToRawInput() {
            #expect(AudioCaptureManager.voiceProcessingAttemptOrder(prefersVoiceProcessing: true) == [true, false])
        }

        @Test
        func voiceProcessingPreservesSystemManagedMicrophoneModeSettings() throws {
            let inputNode = FakeVoiceProcessingInput()

            try AudioCaptureManager.enableVoiceProcessing(inputNode: inputNode)
            AudioCaptureManager.configureVoiceProcessingDucking(inputNode: inputNode)

            #expect(inputNode.enableRequests == [true])
            #expect(inputNode.duckingConfigurationSetCount == 1)
            #expect(!inputNode.voiceProcessingOtherAudioDuckingConfiguration.enableAdvancedDucking.boolValue)
            #expect(inputNode.voiceProcessingOtherAudioDuckingConfiguration.duckingLevel == .min)
        }

        @Test
        func rawInputDoesNotAttemptVoiceProcessing() {
            #expect(AudioCaptureManager.voiceProcessingAttemptOrder(prefersVoiceProcessing: false) == [false])
        }

        @Test
        func voiceProcessingUsesNegotiatedOutputFormat() throws {
            let hardwareFormat = try #require(AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channels: 2
            ))
            let voiceProcessingFormat = try #require(AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channels: 1
            ))

            let result = AudioCaptureManager.captureSourceFormat(
                hardwareFormat: hardwareFormat,
                voiceProcessingFormat: voiceProcessingFormat,
                enablesVoiceProcessing: true
            )

            #expect(result === voiceProcessingFormat)
        }

        @Test
        func rawInputUsesHardwareFormat() throws {
            let hardwareFormat = try #require(AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channels: 2
            ))
            let voiceProcessingFormat = try #require(AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channels: 1
            ))

            let result = AudioCaptureManager.captureSourceFormat(
                hardwareFormat: hardwareFormat,
                voiceProcessingFormat: voiceProcessingFormat,
                enablesVoiceProcessing: false
            )

            #expect(result === hardwareFormat)
        }

        @Test
        func voiceProcessingAllowsDifferentHardwareChannelCountAtMatchingSampleRate() throws {
            let input = try #require(AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channels: 1
            ))
            let matching = try #require(AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channels: 1
            ))
            let differentRate = try #require(AVAudioFormat(
                standardFormatWithSampleRate: 44100,
                channels: 1
            ))
            let differentChannels = try #require(AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channels: 2
            ))

            #expect(AudioCaptureManager.voiceProcessingHardwareFormatsAreCompatible(input, matching))
            #expect(!AudioCaptureManager.voiceProcessingHardwareFormatsAreCompatible(input, differentRate))
            #expect(AudioCaptureManager.voiceProcessingHardwareFormatsAreCompatible(input, differentChannels))
        }

        @Test
        func voiceProcessingUsesProcessedInputAsOutputClientFormat() throws {
            let input = try #require(AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channels: 1
            ))
            let stereoOutputHardware = try #require(AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channels: 2
            ))

            let outputClientFormat = try #require(AudioCaptureManager.voiceProcessingOutputClientFormat(
                inputFormat: input,
                outputHardwareFormat: stereoOutputHardware
            ))

            #expect(outputClientFormat === input)
        }
    }
#endif

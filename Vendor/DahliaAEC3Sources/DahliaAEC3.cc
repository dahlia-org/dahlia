#include "DahliaAEC3.h"

#include <algorithm>
#include <cstring>
#include <new>
#include <vector>

#include "api/audio/audio_processing.h"

struct DahliaAEC3Processor {
    rtc::scoped_refptr<webrtc::AudioProcessing> audio_processing;
    webrtc::StreamConfig stream_config;
    std::vector<float> render_buffer;
};

DahliaAEC3Processor *dahlia_aec3_create(int32_t sample_rate_hz) {
    if (sample_rate_hz < 8000 || sample_rate_hz > 384000 || sample_rate_hz % 100 != 0) {
        return nullptr;
    }

    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;
    config.noise_suppression.enabled = false;
    config.gain_controller1.enabled = false;
    config.gain_controller2.enabled = false;
    config.transient_suppression.enabled = false;

    auto audio_processing = webrtc::AudioProcessingBuilder()
                                .SetConfig(config)
                                .Create();
    if (!audio_processing) {
        return nullptr;
    }

    auto *processor = new (std::nothrow) DahliaAEC3Processor {
        std::move(audio_processing),
        webrtc::StreamConfig(sample_rate_hz, 1),
        std::vector<float>(static_cast<size_t>(sample_rate_hz / 100)),
    };
    if (!processor) {
        return nullptr;
    }
    if (processor->audio_processing->Initialize() != webrtc::AudioProcessing::kNoError) {
        delete processor;
        return nullptr;
    }
    processor->audio_processing->set_stream_delay_ms(0);
    return processor;
}

void dahlia_aec3_destroy(DahliaAEC3Processor *processor) {
    delete processor;
}

size_t dahlia_aec3_frame_size(const DahliaAEC3Processor *processor) {
    return processor ? processor->render_buffer.size() : 0;
}

int32_t dahlia_aec3_process_render(
    DahliaAEC3Processor *processor,
    const float *samples,
    size_t frame_count
) {
    if (!processor || !samples || frame_count != processor->render_buffer.size()) {
        return webrtc::AudioProcessing::kBadParameterError;
    }
    std::memcpy(
        processor->render_buffer.data(),
        samples,
        frame_count * sizeof(float)
    );
    const float *source[] = {processor->render_buffer.data()};
    float *destination[] = {processor->render_buffer.data()};
    return processor->audio_processing->ProcessReverseStream(
        source,
        processor->stream_config,
        processor->stream_config,
        destination
    );
}

int32_t dahlia_aec3_process_capture(
    DahliaAEC3Processor *processor,
    const float *input,
    float *output,
    size_t frame_count
) {
    if (!processor || !input || !output || frame_count != processor->render_buffer.size()) {
        return webrtc::AudioProcessing::kBadParameterError;
    }
    const float *source[] = {input};
    float *destination[] = {output};
    return processor->audio_processing->ProcessStream(
        source,
        processor->stream_config,
        processor->stream_config,
        destination
    );
}

int32_t dahlia_aec3_set_stream_delay_ms(
    DahliaAEC3Processor *processor,
    int32_t delay_ms
) {
    if (!processor) {
        return webrtc::AudioProcessing::kNullPointerError;
    }
    return processor->audio_processing->set_stream_delay_ms(
        std::clamp(delay_ms, 0, 500)
    );
}

DahliaAEC3Statistics dahlia_aec3_get_statistics(
    DahliaAEC3Processor *processor
) {
    DahliaAEC3Statistics result {};
    if (!processor) {
        return result;
    }
    const auto statistics = processor->audio_processing->GetStatistics();
    if (statistics.echo_return_loss_enhancement.has_value()) {
        result.has_echo_return_loss_enhancement = true;
        result.echo_return_loss_enhancement =
            *statistics.echo_return_loss_enhancement;
    }
    if (statistics.delay_ms.has_value()) {
        result.has_delay_ms = true;
        result.delay_ms = *statistics.delay_ms;
    }
    if (statistics.residual_echo_likelihood.has_value()) {
        result.has_residual_echo_likelihood = true;
        result.residual_echo_likelihood =
            *statistics.residual_echo_likelihood;
    }
    return result;
}

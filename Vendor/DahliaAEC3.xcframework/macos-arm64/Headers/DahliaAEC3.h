#ifndef DAHLIA_AEC3_H_
#define DAHLIA_AEC3_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DahliaAEC3Processor DahliaAEC3Processor;

typedef struct DahliaAEC3Statistics {
    bool has_echo_return_loss_enhancement;
    double echo_return_loss_enhancement;
    bool has_delay_ms;
    int32_t delay_ms;
    bool has_residual_echo_likelihood;
    double residual_echo_likelihood;
} DahliaAEC3Statistics;

DahliaAEC3Processor *dahlia_aec3_create(int32_t sample_rate_hz);
void dahlia_aec3_destroy(DahliaAEC3Processor *processor);
size_t dahlia_aec3_frame_size(const DahliaAEC3Processor *processor);
int32_t dahlia_aec3_process_render(
    DahliaAEC3Processor *processor,
    const float *samples,
    size_t frame_count
);
int32_t dahlia_aec3_process_capture(
    DahliaAEC3Processor *processor,
    const float *input,
    float *output,
    size_t frame_count
);
int32_t dahlia_aec3_set_stream_delay_ms(
    DahliaAEC3Processor *processor,
    int32_t delay_ms
);
DahliaAEC3Statistics dahlia_aec3_get_statistics(
    DahliaAEC3Processor *processor
);

#ifdef __cplusplus
}
#endif

#endif

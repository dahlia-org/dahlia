#ifndef DAHLIA_LINDERA_H
#define DAHLIA_LINDERA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t (*DahliaLinderaTokenCallback)(
    void *context,
    const uint8_t *token,
    uintptr_t token_length,
    int32_t start_offset,
    int32_t end_offset
);

enum DahliaLinderaStatus {
    DahliaLinderaStatusOK = 0,
    DahliaLinderaStatusInvalidArgument = 1,
    DahliaLinderaStatusConfigurationError = 2,
    DahliaLinderaStatusTokenizationError = 3,
    DahliaLinderaStatusCallbackError = 4,
    DahliaLinderaStatusPanic = 5
};

int32_t dahlia_lindera_create(void **handle);
void dahlia_lindera_delete(void *handle);
int32_t dahlia_lindera_tokenize(
    void *handle,
    const uint8_t *input,
    uintptr_t input_length,
    void *context,
    DahliaLinderaTokenCallback callback
);
const char *dahlia_lindera_analyzer_version(void);
const char *dahlia_lindera_config_hash(void);

#ifdef __cplusplus
}
#endif

#endif

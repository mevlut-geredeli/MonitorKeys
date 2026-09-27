#include <stdbool.h>
#include <stdint.h>
bool audio_start(uint32_t outputDevice);
void audio_stop(void);
void audio_set_level(float level);
const char *audio_error(void);
uint64_t audio_callbacks(void);
float audio_input_peak(void);
float audio_output_peak(void);
bool audio_self_test(void);

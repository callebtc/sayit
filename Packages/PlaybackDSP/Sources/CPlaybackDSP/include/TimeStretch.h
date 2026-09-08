#ifndef SAYIT_TIME_STRETCH_H
#define SAYIT_TIME_STRETCH_H
#ifdef __cplusplus
extern "C" {
#endif
// Each handle belongs to one serial processing context. No audio callback work.
void *sayit_stretch_create(double sample_rate, double playback_rate);
void sayit_stretch_destroy(void *handle);
// Output is owned by handle until the next call. A negative count signals failure.
const float *sayit_stretch_process(void *handle, const float *input, int count,
                                  int final, int *output_count);
#ifdef __cplusplus
}
#endif
#endif

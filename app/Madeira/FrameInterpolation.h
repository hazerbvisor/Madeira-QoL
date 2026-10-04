#ifndef MADEIRA_FRAME_INTERPOLATION_H
#define MADEIRA_FRAME_INTERPOLATION_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint64_t encoded, scheduled, visible, skipped;
    int visible_valid, status;
    double gpu_ms, added_latency_ms;
} MadeiraInterpolationSnapshot;
int madeira_interpolation_supported(void);
void madeira_interpolation_configure(int mode);
int madeira_interpolation_requested(void);
void madeira_interpolation_gate(int enabled, int native_fps, int reason);
void madeira_interpolation_snapshot(MadeiraInterpolationSnapshot *snapshot);
void madeira_interpolation_pressure(void);
#ifdef __OBJC__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
/* Takes presentation ownership only after resources/history have been reserved. */
int madeira_interpolation_present(id<MTLCommandBuffer> buffer, id<CAMetalDrawable> drawable);
#endif
#ifdef __cplusplus
}
#endif
#endif

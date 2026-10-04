#ifndef MADEIRA_FRAME_INTERPOLATION_TIMING_H
#define MADEIRA_FRAME_INTERPOLATION_TIMING_H
#include <math.h>
#include <stdint.h>
typedef struct { double generated, native; } MadeiraInterpolationTimes;
/* One synthetic midpoint between native frames; never enqueue catch-up frames. */
static inline int madeira_interpolation_times(double now, double last_native, int fps,
                                              MadeiraInterpolationTimes *out) {
    if (!out || !isfinite(now) || now<=0 || !isfinite(last_native) || last_native<0 || (fps!=30 && fps!=60)) return 0;
    double half = 0.5/fps;
    double generated = last_native>0 ? last_native+half : now+0.002;
    if (generated < now+0.001 || generated>now+half) return 0;
    out->generated=generated; out->native=generated+half;
    return out->native>out->generated && (last_native==0 || out->generated>last_native);
}
static inline int madeira_interpolation_confidence(uint32_t tiles, uint32_t invalid,
                                                   uint32_t error_sum, int automatic) {
    if (!tiles || invalid>tiles) return 0;
    double bad=(double)invalid/tiles, error=(double)error_sum/(10000.0*tiles);
    return bad<=(automatic?0.08:0.20) && error<=(automatic?0.025:0.035);
}
#endif

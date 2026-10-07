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
/* Manual 2× accepts varying arrival intervals. Do not pair across a long pause
 * or synthesize faster than the configured display budget. Auto stays strict. */
static inline int madeira_interpolation_pair_period(double interval, int fps, int automatic,
                                                    double *period) {
    if (!period || !isfinite(interval) || (fps!=30 && fps!=60)) return 0;
    double nominal=1.0/fps;
    if (interval < nominal*(automatic?0.9:0.5) || interval > nominal*(automatic?1.1:2.0)) return 0;
    *period=automatic?nominal:fmax(nominal,interval);
    return 1;
}
static inline int madeira_interpolation_variable_times(double now, double last_native,
                                                       double period, int fps,
                                                       MadeiraInterpolationTimes *out) {
    if (!out || !isfinite(now) || now<=0 || !isfinite(last_native) || last_native<0 ||
        !isfinite(period) || (fps!=30 && fps!=60) || period<1.0/fps || period>2.0/fps) return 0;
    double half=period*0.5, earliest=now+0.002;
    /* Rebase late arrivals to the current frame; never enqueue missed frames. */
    double generated=fmax(earliest,last_native>0?last_native+half:earliest);
    if (generated>now+half) return 0;
    out->generated=generated; out->native=generated+half;
    return out->native>out->generated && (last_native==0 || out->generated>last_native);
}
static inline double madeira_interpolation_fallback_time(double now, double last_native, int fps) {
    if (!isfinite(now) || now<=0 || !isfinite(last_native) || last_native<=now || (fps!=30 && fps!=60)) return 0;
    /* A skipped synthetic frame must not make its native successor jump in
     * front of an earlier native frame already scheduled on this layer. */
    return last_native+0.5/fps;
}
static inline int madeira_interpolation_confidence(uint32_t tiles, uint32_t invalid,
                                                   uint32_t error_sum, int automatic) {
    if (!tiles || invalid>tiles) return 0;
    double bad=(double)invalid/tiles, error=(double)error_sum/(10000.0*tiles);
    return bad<=(automatic?0.08:0.20) && error<=(automatic?0.025:0.035);
}
#endif

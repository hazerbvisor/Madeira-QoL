#ifndef MADEIRA_SPATIAL_PRESENTATION_POLICY_H
#define MADEIRA_SPATIAL_PRESENTATION_POLICY_H
#include <math.h>
#include <stdint.h>
#include <stdatomic.h>

/* Bound optional presentation storage independently of the game's resources. */
#define MADEIRA_SPATIAL_SURFACES 3
#define MADEIRA_SPATIAL_BYTES (64ull * 1024 * 1024)
typedef struct {
    uint32_t input_width, input_height, output_width, output_height;
} MadeiraSpatialSize;
typedef struct { _Atomic int finished; } MadeiraSpatialLease;
static inline int madeira_spatial_finish_lease(MadeiraSpatialLease *lease) {
    return !atomic_exchange(&lease->finished, 1);
}

static inline int madeira_spatial_size(double width, double height, int target_width,
                                      int target_height, MadeiraSpatialSize *size) {
    if (!size || !isfinite(width) || !isfinite(height) || width < 1 || height < 1 ||
        width > 4096 || height > 4096 || target_width < 320 || target_height < 240 ||
        target_width > 4096 || target_height > 4096) return 0;
    double factor = fmin(target_width / width, target_height / height);
    /* Downscaling presentation alone cannot reduce the game's render workload. */
    if (factor <= 1 || factor > 4) return 0;
    size->input_width = (uint32_t)llround(width);
    size->input_height = (uint32_t)llround(height);
    size->output_width = (uint32_t)llround(width * factor);
    size->output_height = (uint32_t)llround(height * factor);
    return size->input_width < size->output_width && size->input_height < size->output_height;
}

static inline uint64_t madeira_spatial_surface_bytes(MadeiraSpatialSize size) {
    return (uint64_t)size.input_width * size.input_height * 4;
}
static inline int madeira_spatial_can_allocate(uint64_t resident, MadeiraSpatialSize size) {
    uint64_t bytes = madeira_spatial_surface_bytes(size);
    return bytes && bytes <= MADEIRA_SPATIAL_BYTES && resident <= MADEIRA_SPATIAL_BYTES - bytes;
}
static inline int madeira_spatial_reserve_bytes(_Atomic uint64_t *resident, MadeiraSpatialSize size) {
    uint64_t previous = atomic_load(resident);
    do {
        if (!madeira_spatial_can_allocate(previous, size)) return 0;
    } while (!atomic_compare_exchange_weak(resident, &previous,
                 previous + madeira_spatial_surface_bytes(size)));
    return 1;
}
#endif

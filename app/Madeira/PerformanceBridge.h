#ifndef MADEIRA_PERFORMANCE_BRIDGE_H
#define MADEIRA_PERFORMANCE_BRIDGE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint64_t native_frames, presented_frames, stalls, shader_compiles;
    double mean_ms, p95_ms, max_ms, gpu_ms, shader_ms;
    int gpu_valid, presented_valid, internal_width, internal_height;
    int output_width, output_height, spatial_active, effective_cap;
} MadeiraPerformanceSnapshot;

/* cap -1 retains the legacy renderer pacing, 0 is unlimited. */
void madeira_performance_configure(int cap, int telemetry, const char *archive_path);
void madeira_performance_snapshot(MadeiraPerformanceSnapshot *snapshot);
void madeira_performance_set_cap(int cap);
void madeira_performance_set_telemetry(int enabled);
void madeira_performance_note_shader(double elapsed_ms);
int madeira_performance_renderer_available(void);
int madeira_spatial_supported(void);
int madeira_spatial_configure(int enabled, int width, int height);
void madeira_spatial_adjust_size(double *width, double *height);
int madeira_spatial_encode(uintptr_t buffer, uintptr_t input, uintptr_t output,
                           uintptr_t fence, int compatible);
void madeira_performance_renderer_connected(void);

#ifdef __OBJC__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
/* Return true only when the hook actually scheduled this drawable. */
BOOL madeira_performance_present(id<MTLCommandBuffer> buffer,
                                id<CAMetalDrawable> drawable, double minimum);
void madeira_pipeline_attach(id<MTLDevice> device, id descriptor);
void madeira_pipeline_record(id<MTLDevice> device, id descriptor);
#endif
#ifdef __cplusplus
}
#endif
#endif

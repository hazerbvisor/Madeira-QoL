#ifndef MADEIRA_PERFORMANCE_BRIDGE_H
#define MADEIRA_PERFORMANCE_BRIDGE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint64_t native_frames, presented_frames, stalls, pipeline_requests, generated_encoded_frames;
    double mean_ms, p95_ms, max_ms, gpu_ms, pipeline_ms;
    int gpu_valid, presented_valid, internal_width, internal_height;
    int output_width, output_height, spatial_active, effective_cap, spatial_status;
    int presentation_width, presentation_height;
} MadeiraPerformanceSnapshot;

/* cap -1 retains the legacy renderer pacing, 0 is unlimited. */
void madeira_performance_configure(int cap, int telemetry, const char *archive_path);
void madeira_performance_snapshot(MadeiraPerformanceSnapshot *snapshot);
void madeira_performance_set_cap(int cap);
void madeira_performance_set_telemetry(int enabled);
void madeira_performance_cache_pressure(int level);
uint64_t madeira_available_memory(void);
void madeira_performance_note_pipeline(double elapsed_ms);
void madeira_performance_note_generated_encode(void);
int madeira_performance_renderer_available(void);
int madeira_spatial_supported(void);
int madeira_spatial_requested(void);
int madeira_spatial_configure(int enabled, int width, int height);
void madeira_performance_renderer_connected(void);

#ifdef __OBJC__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
/* Return true only when the hook actually scheduled this drawable. */
BOOL madeira_performance_present(id<MTLCommandBuffer> buffer,
                                id<CAMetalDrawable> drawable, double minimum);
/* The renderer sees its original viewport-sized texture; only final display is larger. */
void madeira_spatial_layer_configure(CAMetalLayer *layer, double width, double height);
void madeira_spatial_layer_requested_size(CAMetalLayer *layer, double *width, double *height);
id<CAMetalDrawable> madeira_spatial_next_drawable(CAMetalLayer *layer);
id<MTLTexture> madeira_spatial_drawable_texture(id<CAMetalDrawable> drawable);
void madeira_spatial_track_encoder(id<MTLRenderCommandEncoder> encoder, id<MTLCommandBuffer> buffer,
                                   id<MTLTexture> target);
void madeira_spatial_note_backbuffer(id<MTLRenderCommandEncoder> encoder, id<MTLTexture> texture,
                                    unsigned index);
void madeira_pipeline_attach(id<MTLDevice> device, id descriptor);
void madeira_pipeline_record(id<MTLDevice> device, id descriptor);
#endif
#ifdef __cplusplus
}
#endif
#endif

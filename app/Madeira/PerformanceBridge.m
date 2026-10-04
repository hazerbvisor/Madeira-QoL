#import "PerformanceBridge.h"
#include "FrameDeadline.h"
#include "SpatialPresentationPolicy.h"
#include <stdatomic.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <os/proc.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>

static _Atomic int cap = -1, telemetry, connected;
static pthread_mutex_t samplesLock = PTHREAD_MUTEX_INITIALIZER;
static MadeiraPerformanceSnapshot metrics;
static double intervals[128], lastSubmit, lastStallLog;
static unsigned cursor, sampleCount;
static dispatch_queue_t archiveQueue;
static pthread_mutex_t archiveLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *archivePath;
static id<MTLBinaryArchive> pipelineArchive;
static uint64_t archiveGeneration;
static BOOL archiveDirty, saveScheduled;
static BOOL archiveAttempted;
static unsigned archiveRecords;
static _Atomic unsigned pendingArchiveRecords;
static _Atomic int cachePressure;
static _Atomic int spatialEnabled, outputWidth, outputHeight;
static _Atomic uint64_t spatialGeneration;
static _Atomic uint64_t spatialResidentBytes;
static pthread_mutex_t spatialRegistryLock = PTHREAD_MUTEX_INITIALIZER;
static NSHashTable *spatialLayers;

/* These objects never cross the Wine ABI. Both i386 and x86_64 thunks continue
 * returning ordinary native object handles with their existing retain rules. */
@interface MadeiraSpatialSurface : NSObject
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, strong) id<MTLFXSpatialScaler> scaler;
@property(nonatomic, strong) id<MTLRenderPipelineState> fallback;
@property(nonatomic) MadeiraSpatialSize size;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL leased;
@property(nonatomic) uint64_t accountedBytes;
@end
@implementation MadeiraSpatialSurface
- (void)dealloc { if (_accountedBytes) atomic_fetch_sub(&spatialResidentBytes, _accountedBytes); }
@end

@interface MadeiraSpatialLayer : NSObject
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSMutableArray<MadeiraSpatialSurface *> *surfaces;
@property(nonatomic) CGSize requestedSize;
@property(nonatomic) MadeiraSpatialSize failedSize;
@property(nonatomic) NSUInteger failedFormat;
@property(nonatomic) uint64_t failedGeneration;
@end
@implementation MadeiraSpatialLayer
- (instancetype)init {
    if ((self = [super init])) { _lock = [NSLock new]; _surfaces = [NSMutableArray new]; }
    return self;
}
@end

@interface MadeiraSpatialFrame : NSObject { @public MadeiraSpatialLease lease; }
@property(nonatomic, strong) MadeiraSpatialLayer *owner;
@property(nonatomic, strong) MadeiraSpatialSurface *surface;
@property(nonatomic) BOOL submitted;
@end
@implementation MadeiraSpatialFrame
- (instancetype)init {
    if ((self = [super init])) atomic_init(&lease.finished, 0);
    return self;
}
- (void)dealloc {
    // A dropped/unsubmitted drawable also returns its optional storage.
    [_owner.lock lock];
    if (madeira_spatial_finish_lease(&lease)) _surface.leased = NO;
    [_owner.lock unlock];
}
@end
static char spatialLayerKey, spatialFrameKey, spatialStatusKey;
static char presentTextureKey, presentEncoderKey, presentObservationKey;
@interface MadeiraPresentObservation : NSObject
@property(nonatomic) CGSize gameSize;
@property(nonatomic) CGSize presentationSize;
@end
@implementation MadeiraPresentObservation
@end

int madeira_spatial_requested(void) {
    const char *remote = getenv("DXMT_REMOTE_METAL");
    return !(remote && *remote) && atomic_load(&spatialEnabled);
}

void madeira_spatial_layer_configure(CAMetalLayer *layer, double width, double height) {
    MadeiraSpatialLayer *state = objc_getAssociatedObject(layer, &spatialLayerKey);
    if (!state && !madeira_spatial_requested()) return;
    if (!state) {
        state = [MadeiraSpatialLayer new];
        objc_setAssociatedObject(layer, &spatialLayerKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pthread_mutex_lock(&spatialRegistryLock);
        if (!spatialLayers) spatialLayers = [NSHashTable weakObjectsHashTable];
        [spatialLayers addObject:state];
        pthread_mutex_unlock(&spatialRegistryLock);
    }
    [state.lock lock]; state.requestedSize = CGSizeMake(width, height); [state.lock unlock];
}

static void spatialPurge(void) {
    pthread_mutex_lock(&spatialRegistryLock);
    NSArray *states = spatialLayers.allObjects;
    pthread_mutex_unlock(&spatialRegistryLock);
    for (MadeiraSpatialLayer *state in states) {
        [state.lock lock];
        for (MadeiraSpatialSurface *surface in [state.surfaces copy])
            if (!surface.leased) [state.surfaces removeObject:surface];
        [state.lock unlock];
    }
}

void madeira_spatial_layer_requested_size(CAMetalLayer *layer, double *width, double *height) {
    MadeiraSpatialLayer *state = objc_getAssociatedObject(layer, &spatialLayerKey);
    if (!state) return;
    [state.lock lock]; CGSize size = state.requestedSize; [state.lock unlock];
    if (size.width > 0 && size.height > 0) { *width = size.width; *height = size.height; }
}

static id<MTLRenderPipelineState> spatialFallback(id<MTLDevice> device, MTLPixelFormat format) {
    // Reuse the native renderer's verified, compiled Metal 3.1 library instead
    // of introducing a shader source or requiring an offline Metal compiler.
    // All color conversion, gamma and MSAA resolve already happened upstream.
    extern unsigned char dxmt_command[];
    extern unsigned int dxmt_command_len;
    NSError *error = nil;
    dispatch_data_t data = dispatch_data_create(dxmt_command, dxmt_command_len,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
    if (!library) return nil;
    MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
    bool disabled = false;
    for (NSUInteger index = 0x100; index <= 0x105; index++)
        [constants setConstantValue:&disabled type:MTLDataTypeBool atIndex:index];
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"vs_present_quad"];
    desc.fragmentFunction = [library newFunctionWithName:@"fs_present_quad" constantValues:constants error:&error];
    if (!desc.vertexFunction || !desc.fragmentFunction) return nil;
    desc.colorAttachments[0].pixelFormat = format;
    madeira_pipeline_attach(device, desc);
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (pipeline) madeira_pipeline_record(device, desc);
    return pipeline;
}

static MadeiraSpatialSurface *spatialReserve(MadeiraSpatialLayer *state, id<MTLDevice> device,
                                            MTLPixelFormat format, MadeiraSpatialSize size) {
    uint64_t generation = atomic_load(&spatialGeneration);
    [state.lock lock];
    uint64_t resident = 0;
    MadeiraSpatialSurface *reusable = nil;
    for (MadeiraSpatialSurface *surface in [state.surfaces copy]) {
        MadeiraSpatialSize previous = surface.size;
        BOOL match = surface.generation == generation && surface.texture.device == device &&
            surface.texture.pixelFormat == format && !memcmp(&previous, &size, sizeof(size));
        if (!surface.leased && !match) [state.surfaces removeObject:surface];
        else {
            resident += madeira_spatial_surface_bytes(surface.size);
            if (!surface.leased) reusable = surface;
        }
    }
    if (reusable) { reusable.leased = YES; [state.lock unlock]; return reusable; }
    MadeiraSpatialSize failed = state.failedSize;
    if (state.surfaces.count >= MADEIRA_SPATIAL_SURFACES || !madeira_spatial_can_allocate(resident, size) ||
        (state.failedGeneration == generation && state.failedFormat == format &&
         !memcmp(&failed, &size, sizeof(size)))) { [state.lock unlock]; return nil; }
    [state.lock unlock];

    if ([NSThread isMainThread] || !madeira_spatial_reserve_bytes(&spatialResidentBytes, size)) return nil;

    MTLFXSpatialScalerDescriptor *desc = [MTLFXSpatialScalerDescriptor new];
    desc.inputWidth = size.input_width; desc.inputHeight = size.input_height;
    desc.outputWidth = size.output_width; desc.outputHeight = size.output_height;
    desc.colorTextureFormat = format; desc.outputTextureFormat = format;
    desc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    id<MTLFXSpatialScaler> scaler = [desc newSpatialScalerWithDevice:device];
    id<MTLRenderPipelineState> fallback = nil;
    // Share the immutable fallback PSO across the three independent in-flight scalers.
    [state.lock lock];
    for (MadeiraSpatialSurface *surface in state.surfaces)
        if (surface.texture.device == device && surface.texture.pixelFormat == format) { fallback = surface.fallback; break; }
    [state.lock unlock];
    if (!fallback && scaler) fallback = spatialFallback(device, format);
    MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
        width:size.input_width height:size.input_height mipmapped:NO];
    textureDesc.storageMode = MTLStorageModePrivate;
    textureDesc.hazardTrackingMode = MTLHazardTrackingModeTracked;
    textureDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | scaler.colorTextureUsage;
    id<MTLTexture> texture = scaler && fallback ? [device newTextureWithDescriptor:textureDesc] : nil;
    MadeiraSpatialSurface *surface = nil;
    if (texture) {
        surface = [MadeiraSpatialSurface new]; surface.texture = texture; surface.scaler = scaler;
        surface.fallback = fallback; surface.size = size; surface.generation = generation; surface.leased = YES;
        surface.accountedBytes = madeira_spatial_surface_bytes(size);
    } else atomic_fetch_sub(&spatialResidentBytes, madeira_spatial_surface_bytes(size));
    [state.lock lock];
    // Another encode thread can reserve during resource creation. Never grow the pool unchecked.
    resident = 0;
    for (MadeiraSpatialSurface *existing in state.surfaces) resident += madeira_spatial_surface_bytes(existing.size);
    if (surface && state.surfaces.count < MADEIRA_SPATIAL_SURFACES && madeira_spatial_can_allocate(resident, size))
        [state.surfaces addObject:surface];
    else if (!texture) {
        surface = nil;
        state.failedSize = size; state.failedFormat = format; state.failedGeneration = generation;
    } else surface = nil;
    [state.lock unlock];
    return surface;
}

id<CAMetalDrawable> madeira_spatial_next_drawable(CAMetalLayer *layer) {
    MadeiraSpatialLayer *state = objc_getAssociatedObject(layer, &spatialLayerKey);
    if (!state) return [layer nextDrawable];
    [state.lock lock]; CGSize requested = state.requestedSize; [state.lock unlock];
    MadeiraSpatialSize size;
    MadeiraSpatialSurface *surface = nil;
    MTLPixelFormat format = layer.pixelFormat;
    int status = 0;
    if (madeira_spatial_requested()) {
        if (atomic_load(&cachePressure)) status = 3;
        else if (layer.framebufferOnly || layer.wantsExtendedDynamicRangeContent ||
            (format != MTLPixelFormatBGRA8Unorm && format != MTLPixelFormatRGBA8Unorm) ||
            ![MTLFXSpatialScalerDescriptor supportsDevice:layer.device]) status = 4;
        else if (!madeira_spatial_size(requested.width, requested.height,
                 atomic_load(&outputWidth), atomic_load(&outputHeight), &size)) status = 5;
        else { surface = spatialReserve(state, layer.device, format, size); status = surface ? 1 : 6; }
    }
    CGSize actual = surface ? CGSizeMake(size.output_width, size.output_height) : requested;
    if (!CGSizeEqualToSize(layer.drawableSize, actual)) {
        void (^update)(void) = ^{ layer.drawableSize = actual; };
        if ([NSThread isMainThread]) update(); else dispatch_sync(dispatch_get_main_queue(), update);
    }
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (drawable) {
        // A recycled drawable may still carry its completed prior frame. Clear
        // it even when this acquisition falls back to the original renderer.
        objc_setAssociatedObject(drawable, &spatialFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(drawable, &spatialStatusKey, @(status), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (surface && drawable) {
        MadeiraSpatialFrame *frame = [MadeiraSpatialFrame new]; frame.owner = state; frame.surface = surface;
        objc_setAssociatedObject(drawable, &spatialFrameKey, frame, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (surface) { [state.lock lock]; surface.leased = NO; [state.lock unlock]; }
    return drawable;
}

id<MTLTexture> madeira_spatial_drawable_texture(id<CAMetalDrawable> drawable) {
    MadeiraSpatialFrame *frame = objc_getAssociatedObject(drawable, &spatialFrameKey);
    id<MTLTexture> texture = frame ? frame.surface.texture : drawable.texture;
    if (texture && atomic_load(&telemetry))
        objc_setAssociatedObject(texture, &presentTextureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return texture;
}

void madeira_spatial_track_encoder(id<MTLRenderCommandEncoder> encoder, id<MTLCommandBuffer> buffer,
                                   id<MTLTexture> target) {
    if (!atomic_load(&telemetry) || !encoder || !objc_getAssociatedObject(target, &presentTextureKey)) return;
    MadeiraPresentObservation *observation = [MadeiraPresentObservation new];
    observation.presentationSize = CGSizeMake(target.width, target.height);
    objc_setAssociatedObject(encoder, &presentEncoderKey, observation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(buffer, &presentObservationKey, observation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void madeira_spatial_note_backbuffer(id<MTLRenderCommandEncoder> encoder, id<MTLTexture> texture, unsigned index) {
    if (!atomic_load(&telemetry) || index != 0 || !texture) return;
    MadeiraPresentObservation *observation = objc_getAssociatedObject(encoder, &presentEncoderKey);
    // Only the identified DXMT final presentation pass's color source is known.
    // Arbitrary scene render targets/depth or shader bindings are never guessed.
    if (observation) observation.gameSize = CGSizeMake(texture.width, texture.height);
}

static void spatialFinish(id<MTLCommandBuffer> buffer, id<CAMetalDrawable> drawable) {
    if (atomic_load(&telemetry)) {
        MadeiraPresentObservation *observation = objc_getAssociatedObject(buffer, &presentObservationKey);
        CGSize game = observation ? observation.gameSize : CGSizeZero;
        CGSize presentation = observation ? observation.presentationSize : CGSizeZero;
        pthread_mutex_lock(&samplesLock);
        metrics.internal_width = (int)game.width; metrics.internal_height = (int)game.height;
        metrics.presentation_width = (int)presentation.width; metrics.presentation_height = (int)presentation.height;
        pthread_mutex_unlock(&samplesLock);
    }
    MadeiraSpatialFrame *frame = objc_getAssociatedObject(drawable, &spatialFrameKey);
    if (!frame) {
        if (atomic_load(&telemetry)) {
            pthread_mutex_lock(&samplesLock);
            metrics.spatial_active = 0;
            metrics.spatial_status = [objc_getAssociatedObject(drawable, &spatialStatusKey) intValue];
            pthread_mutex_unlock(&samplesLock);
        }
        return;
    }
    if (frame.submitted) return;
    frame.submitted = YES;
    MadeiraSpatialSurface *surface = frame.surface;
    id<MTLTexture> output = drawable.texture;
    BOOL encoded = output.device == buffer.device &&
        output.width == surface.size.output_width && output.height == surface.size.output_height &&
        output.pixelFormat == surface.texture.pixelFormat &&
        (output.usage & surface.scaler.outputTextureUsage) == surface.scaler.outputTextureUsage;
    if (encoded) {
        surface.scaler.colorTexture = surface.texture; surface.scaler.outputTexture = output;
        surface.scaler.inputContentWidth = surface.size.input_width;
        surface.scaler.inputContentHeight = surface.size.input_height;
        [surface.scaler encodeToCommandBuffer:buffer];
    } else {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = output;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:surface.fallback];
        [encoder setFragmentTexture:surface.texture atIndex:0];
        float metadata[3] = {1, 10000, 100}; // DXMTPresentMetadata, neutral SDR output
        [encoder setFragmentBytes:metadata length:sizeof(metadata) atIndex:0];
        [encoder setViewport:(MTLViewport){0, 0, output.width, output.height, 0, 1}];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
    }
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
        (void)done;
        // Do not reuse or discard GPU-referenced textures before completion.
        surface.scaler.colorTexture = nil; surface.scaler.outputTexture = nil;
        [frame.owner.lock lock];
        if (madeira_spatial_finish_lease(&frame->lease)) surface.leased = NO;
        if (atomic_load(&cachePressure) || surface.generation != atomic_load(&spatialGeneration))
            [frame.owner.surfaces removeObject:surface];
        [frame.owner.lock unlock];
    }];
    if (atomic_load(&telemetry)) {
        pthread_mutex_lock(&samplesLock);
        metrics.presentation_width = (int)surface.texture.width; metrics.presentation_height = (int)surface.texture.height;
        metrics.spatial_active = encoded;
        metrics.spatial_status = encoded ? 1 : 2;
        pthread_mutex_unlock(&samplesLock);
    }
}

int madeira_spatial_supported(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return madeira_performance_renderer_available() && device &&
        [MTLFXSpatialScalerDescriptor supportsDevice:device];
}

int madeira_spatial_configure(int enabled, int width, int height) {
    BOOL supported = enabled && width >= 320 && height >= 240 && width <= 8192 && height <= 8192 && madeira_spatial_supported();
    atomic_store(&spatialEnabled, supported);
    atomic_store(&outputWidth, width); atomic_store(&outputHeight, height);
    atomic_fetch_add(&spatialGeneration, 1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ spatialPurge(); });
    return supported;
}

static dispatch_queue_t cacheQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ archiveQueue = dispatch_queue_create("madeira.pipeline-cache", DISPATCH_QUEUE_SERIAL); });
    return archiveQueue;
}

__attribute__((weak)) int madeira_dxmt_performance_hooks_v1(void) { return 0; }
void madeira_performance_renderer_connected(void) { atomic_store(&connected, 1); }
int madeira_performance_renderer_available(void) {
    const char *remote = getenv("DXMT_REMOTE_METAL");
    if (remote && *remote) return 0;
    return atomic_load(&connected) || madeira_dxmt_performance_hooks_v1();
}
void madeira_performance_set_cap(int value) { atomic_store(&cap, value); }
void madeira_performance_set_telemetry(int enabled) {
    int wasEnabled = atomic_exchange(&telemetry, !!enabled);
    if (enabled && !wasEnabled) {
        pthread_mutex_lock(&samplesLock);
        lastSubmit = lastStallLog = 0; cursor = sampleCount = 0;
        pthread_mutex_unlock(&samplesLock);
    }
}

uint64_t madeira_available_memory(void) { return os_proc_available_memory(); }

void madeira_performance_cache_pressure(int level) {
    level = MAX(0, MIN(level, 2));
    atomic_store(&cachePressure, level);
    atomic_fetch_add(&spatialGeneration, 1);
    dispatch_async(cacheQueue(), ^{
        // Only optional renderer-owned state is released. Live game resources,
        // pipeline states and executable FEX pages remain owned by their runtime.
        if (level) spatialPurge();
        pthread_mutex_lock(&archiveLock);
        if (level >= 2) {
            pipelineArchive = nil; archiveGeneration++;
            archiveDirty = saveScheduled = NO; archiveAttempted = NO;
        }
        pthread_mutex_unlock(&archiveLock);
    });
}

void madeira_performance_configure(int value, int enabled, const char *path) {
    madeira_performance_set_cap(value);
    madeira_performance_set_telemetry(enabled);
    pthread_mutex_lock(&samplesLock);
    metrics = (MadeiraPerformanceSnapshot){0};
    lastSubmit = lastStallLog = 0; cursor = sampleCount = 0;
    pthread_mutex_unlock(&samplesLock);
    NSString *newPath = path && *path ? @(path) : nil;
    dispatch_sync(cacheQueue(), ^{
        pthread_mutex_lock(&archiveLock);
        archivePath = newPath;
        pipelineArchive = nil;
        archiveGeneration++;
        archiveDirty = saveScheduled = archiveAttempted = NO; archiveRecords = 0;
        pthread_mutex_unlock(&archiveLock);
    });
}

static int compareDouble(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

void madeira_performance_snapshot(MadeiraPerformanceSnapshot *out) {
    if (!out) return;
    double sorted[128]; unsigned count;
    pthread_mutex_lock(&samplesLock);
    *out = metrics; count = sampleCount;
    metrics.pipeline_ms = 0; // peak preparation time since the last observation
    memcpy(sorted, intervals, count * sizeof(double));
    pthread_mutex_unlock(&samplesLock);
    out->effective_cap = atomic_load(&cap);
    if (count) {
        double sum = 0;
        for (unsigned i = 0; i < count; i++) sum += sorted[i];
        qsort(sorted, count, sizeof(double), compareDouble);
        out->mean_ms = sum / count;
        out->p95_ms = sorted[(count * 95 - 1) / 100];
        out->max_ms = sorted[count - 1];
    }
}

void madeira_performance_note_pipeline(double ms) {
    if (!atomic_load(&telemetry)) return;
    pthread_mutex_lock(&samplesLock);
    metrics.pipeline_requests++;
    metrics.pipeline_ms = MAX(metrics.pipeline_ms, ms);
    pthread_mutex_unlock(&samplesLock);
}

void madeira_performance_note_generated_encode(void) {
    if (!atomic_load(&telemetry)) return;
    pthread_mutex_lock(&samplesLock);
    metrics.generated_encoded_frames++;
    pthread_mutex_unlock(&samplesLock);
}

BOOL madeira_performance_present(id<MTLCommandBuffer> buffer,
                                 id<CAMetalDrawable> drawable, double minimum) {
    if (!buffer || !drawable) return NO;
    spatialFinish(buffer, drawable);
    int targetFPS = atomic_load(&cap);
    if (targetFPS >= 0) {
        static _Thread_local MadeiraFrameDeadline deadline;
        static mach_timebase_info_data_t timebase;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
        double period = targetFPS > 0 ? 1.0 / targetFPS : 0;
        period = MAX(period, MAX(minimum, 0)); // never defeat a game's slower cadence
        uint64_t now = (uint64_t)((double)mach_absolute_time() * timebase.numer / timebase.denom);
        uint64_t target = madeira_frame_deadline(&deadline, now, (uint64_t)(period * 1e9));
        if (target > now)
            mach_wait_until((uint64_t)((double)target * timebase.denom / timebase.numer));
    }
    if (atomic_load(&telemetry)) {
        double now = CACurrentMediaTime();
        pthread_mutex_lock(&samplesLock);
        if (lastSubmit && now > lastSubmit) {
            double dt = (now - lastSubmit) * 1000;
            intervals[cursor] = dt; cursor = (cursor + 1) % 128;
            sampleCount = MIN(sampleCount + 1, 128);
            if (dt > 100) {
                metrics.stalls++;
                if (now - lastStallLog > 5) {
                    fprintf(stderr, "[performance] present submission stall %.1f ms\n", dt);
                    lastStallLog = now;
                }
            }
        }
        lastSubmit = now; metrics.native_frames++;
        metrics.output_width = (int)drawable.texture.width;
        metrics.output_height = (int)drawable.texture.height;
        pthread_mutex_unlock(&samplesLock);
        [buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
            double start = done.GPUStartTime, end = done.GPUEndTime;
            if (done.status == MTLCommandBufferStatusCompleted && start > 0 && end >= start) {
                pthread_mutex_lock(&samplesLock);
                double ms = (end - start) * 1000;
                metrics.gpu_ms = metrics.gpu_valid ? metrics.gpu_ms * .8 + ms * .2 : ms;
                metrics.gpu_valid = 1;
                pthread_mutex_unlock(&samplesLock);
            }
        }];
        [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
            if (shown.presentedTime <= 0) return; // zero is not evidence of visible frames
            pthread_mutex_lock(&samplesLock);
            metrics.presented_frames++; metrics.presented_valid = 1;
            pthread_mutex_unlock(&samplesLock);
        }];
    }
    if (targetFPS < 0) return NO;
    [buffer presentDrawable:drawable];
    return YES;
}

static void ensureArchive(id<MTLDevice> device) {
    if (pipelineArchive || archiveAttempted || !archivePath.length || atomic_load(&cachePressure)) return;
    archiveAttempted = YES;
    MTLBinaryArchiveDescriptor *desc = [MTLBinaryArchiveDescriptor new];
    NSDictionary *existing = [[NSFileManager defaultManager] attributesOfItemAtPath:archivePath error:nil];
    if ([existing fileSize] > 256 * 1024 * 1024)
        [[NSFileManager defaultManager] removeItemAtPath:archivePath error:nil];
    else if ([[NSFileManager defaultManager] fileExistsAtPath:archivePath])
        desc.url = [NSURL fileURLWithPath:archivePath];
    NSError *error = nil;
    pipelineArchive = [device newBinaryArchiveWithDescriptor:desc error:&error];
    if (!pipelineArchive && desc.url) {
        // An incompatible or truncated archive is a cache miss, never a launch error.
        [[NSFileManager defaultManager] removeItemAtPath:archivePath error:nil];
        desc.url = nil;
        pipelineArchive = [device newBinaryArchiveWithDescriptor:desc error:&error];
    }
}

void madeira_pipeline_attach(id<MTLDevice> device, id descriptor) {
    // First initialization is on the launch/compilation worker. Afterwards
    // a short lock reads the archive; it never waits for disk serialization.
    pthread_mutex_lock(&archiveLock);
    BOOL needsInitialization = archivePath.length && !pipelineArchive && !archiveAttempted && !atomic_load(&cachePressure);
    pthread_mutex_unlock(&archiveLock);
    if (needsInitialization) {
    dispatch_sync(cacheQueue(), ^{
        pthread_mutex_lock(&archiveLock);
        ensureArchive(device);
        pthread_mutex_unlock(&archiveLock);
    });
    }
    pthread_mutex_lock(&archiveLock);
    id<MTLBinaryArchive> archive = pipelineArchive;
    pthread_mutex_unlock(&archiveLock);
    if (archive && ![descriptor binaryArchives].count)
        [descriptor setBinaryArchives:@[archive]];
}

static void scheduleArchiveSave(void) {
    if (saveScheduled || !pipelineArchive) return;
    saveScheduled = YES;
    uint64_t generation = archiveGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), cacheQueue(), ^{
        if (generation != archiveGeneration) return;
        saveScheduled = NO;
        if (!archiveDirty || !archivePath.length || atomic_load(&cachePressure)) return;
        NSString *temporary = [archivePath stringByAppendingString:@".tmp"];
        NSError *error = nil;
        if ([pipelineArchive serializeToURL:[NSURL fileURLWithPath:temporary] error:&error]) {
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:temporary error:nil];
            if ([attributes fileSize] <= 256 * 1024 * 1024) {
                if (rename(temporary.fileSystemRepresentation, archivePath.fileSystemRepresentation) == 0)
                    archiveDirty = NO;
            } else {
                // Stop optional population rather than retaining an oversized
                // archive indefinitely. Existing compiled PSOs are unaffected.
                pthread_mutex_lock(&archiveLock);
                pipelineArchive = nil; archiveGeneration++; archiveDirty = NO;
                pthread_mutex_unlock(&archiveLock);
            }
            [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
        }
    });
}

void madeira_pipeline_record(id<MTLDevice> device, id descriptor) {
    pthread_mutex_lock(&archiveLock);
    BOOL enabled = archivePath.length > 0;
    uint64_t generation = archiveGeneration;
    pthread_mutex_unlock(&archiveLock);
    if (!enabled || atomic_load(&cachePressure)) return;
    if (atomic_fetch_add(&pendingArchiveRecords, 1) >= 32) {
        atomic_fetch_sub(&pendingArchiveRecords, 1); return;
    }
    id copy = [descriptor copy];
    // Keep expensive archive maintenance off the UI and renderer threads.
    dispatch_async(cacheQueue(), ^{
        atomic_fetch_sub(&pendingArchiveRecords, 1);
        if (generation != archiveGeneration || atomic_load(&cachePressure) || archiveRecords >= 2000) return;
        pthread_mutex_lock(&archiveLock);
        ensureArchive(device);
        pthread_mutex_unlock(&archiveLock);
        NSError *error = nil;
        BOOL success = NO;
        if ([copy isKindOfClass:[MTLRenderPipelineDescriptor class]])
            success = [pipelineArchive addRenderPipelineFunctionsWithDescriptor:copy error:&error];
        else if ([copy isKindOfClass:[MTLComputePipelineDescriptor class]])
            success = [pipelineArchive addComputePipelineFunctionsWithDescriptor:copy error:&error];
        if (success) { archiveRecords++; archiveDirty = YES; scheduleArchiveSave(); }
    });
}

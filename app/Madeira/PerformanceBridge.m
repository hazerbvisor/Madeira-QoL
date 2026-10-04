#import "PerformanceBridge.h"
#include "FrameDeadline.h"
#include <stdatomic.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <os/proc.h>
#import <MetalFX/MetalFX.h>

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
static _Thread_local unsigned nativePropsDepth;
static pthread_mutex_t spatialLock = PTHREAD_MUTEX_INITIALIZER;
static id<MTLFXSpatialScaler> spatialScaler;
static NSUInteger scalerDimensions[6];
static BOOL scalerFailed;

int madeira_spatial_supported(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return madeira_performance_renderer_available() && device &&
        [MTLFXSpatialScalerDescriptor supportsDevice:device];
}

int madeira_spatial_configure(int enabled, int width, int height) {
    BOOL supported = enabled && width >= 320 && height >= 240 && width <= 8192 && height <= 8192 && madeira_spatial_supported();
    atomic_store(&spatialEnabled, supported);
    atomic_store(&outputWidth, width); atomic_store(&outputHeight, height);
    pthread_mutex_lock(&spatialLock);
    spatialScaler = nil; memset(scalerDimensions, 0, sizeof(scalerDimensions)); scalerFailed = NO;
    pthread_mutex_unlock(&spatialLock);
    return supported;
}

void madeira_spatial_native_props(int active) {
    if (active) nativePropsDepth++;
    else if (nativePropsDepth) nativePropsDepth--;
}
int madeira_spatial_native_props_active(void) { return nativePropsDepth > 0; }

void madeira_spatial_adjust_size(int native, double *width, double *height) {
    if (!native || !atomic_load(&spatialEnabled) || !width || !height || !isfinite(*width) || !isfinite(*height) || *width <= 0 || *height <= 0) return;
    double factor = MIN((double)atomic_load(&outputWidth) / *width,
                        (double)atomic_load(&outputHeight) / *height);
    // Preserve unusual swapchain aspect ratios; never resize the game's resources.
    // Native D3D9 may already multiply the window by UIKit's contentsScale.
    // The explicit output target must also replace that oversized drawable.
    if (factor > 0 && factor <= 4) { *width = round(*width * factor); *height = round(*height * factor); }
}

int madeira_spatial_encode(uintptr_t command, uintptr_t inputHandle, uintptr_t outputHandle,
                          uintptr_t fenceHandle, int compatible) {
    // The diagnostic remote backend uses tagged handles, not local Obj-C
    // pointers. Never message them, including for telemetry/fallback sizing.
    const char *remote = getenv("DXMT_REMOTE_METAL");
    if (remote && *remote) return 0;
    id<MTLCommandBuffer> buffer = (__bridge id<MTLCommandBuffer>)(void *)command;
    id<MTLTexture> input = (__bridge id<MTLTexture>)(void *)inputHandle;
    id<MTLTexture> output = (__bridge id<MTLTexture>)(void *)outputHandle;
    BOOL encoded = NO;
    if (atomic_load(&spatialEnabled) && !atomic_load(&cachePressure) && compatible && input && output &&
        (input.pixelFormat == MTLPixelFormatBGRA8Unorm || input.pixelFormat == MTLPixelFormatRGBA8Unorm) &&
        (output.pixelFormat == MTLPixelFormatBGRA8Unorm || output.pixelFormat == MTLPixelFormatRGBA8Unorm) &&
        input.width < output.width && input.height < output.height &&
        input.sampleCount == 1 && output.sampleCount == 1 &&
        input.textureType == MTLTextureType2D && output.textureType == MTLTextureType2D) {
        pthread_mutex_lock(&spatialLock);
        NSUInteger dimensions[] = {input.width, input.height, input.pixelFormat,
                                    output.width, output.height, output.pixelFormat};
        if (memcmp(scalerDimensions, dimensions, sizeof(dimensions))) {
            memcpy(scalerDimensions, dimensions, sizeof(dimensions));
            scalerFailed = NO; spatialScaler = nil;
        }
        if (!spatialScaler && !scalerFailed) {
            MTLFXSpatialScalerDescriptor *desc = [MTLFXSpatialScalerDescriptor new];
            desc.inputWidth = input.width; desc.inputHeight = input.height;
            desc.outputWidth = output.width; desc.outputHeight = output.height;
            desc.colorTextureFormat = input.pixelFormat; desc.outputTextureFormat = output.pixelFormat;
            desc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
            spatialScaler = [desc newSpatialScalerWithDevice:buffer.device];
            scalerFailed = spatialScaler == nil;
        }
        if (spatialScaler && (input.usage & spatialScaler.colorTextureUsage) == spatialScaler.colorTextureUsage &&
            (output.usage & spatialScaler.outputTextureUsage) == spatialScaler.outputTextureUsage) {
            spatialScaler.colorTexture = input; spatialScaler.outputTexture = output;
            spatialScaler.inputContentWidth = input.width; spatialScaler.inputContentHeight = input.height;
            spatialScaler.fence = (__bridge id<MTLFence>)(void *)fenceHandle;
            [spatialScaler encodeToCommandBuffer:buffer];
            encoded = YES;
        }
        pthread_mutex_unlock(&spatialLock);
    }
    if (!atomic_load(&telemetry)) return encoded;
    pthread_mutex_lock(&samplesLock);
    metrics.internal_width = (int)input.width; metrics.internal_height = (int)input.height;
    metrics.output_width = (int)output.width; metrics.output_height = (int)output.height;
    metrics.spatial_active = encoded;
    pthread_mutex_unlock(&samplesLock);
    return encoded;
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
    dispatch_async(cacheQueue(), ^{
        // Only optional renderer-owned state is released. Live game resources,
        // pipeline states and executable FEX pages remain owned by their runtime.
        pthread_mutex_lock(&spatialLock);
        if (level) spatialScaler = nil;
        pthread_mutex_unlock(&spatialLock);
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

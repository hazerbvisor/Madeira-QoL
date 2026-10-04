#import "FrameInterpolation.h"
#import "PerformanceBridge.h"
#include "FrameInterpolationTiming.h"
#include "OpticalFlowSource.h"
#import <objc/runtime.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdlib.h>

static _Atomic int requestedMode, gateEnabled, nativeFPS;
static _Atomic uint64_t epoch, residentBytes;
static pthread_mutex_t registryLock = PTHREAD_MUTEX_INITIALIZER, metricsLock = PTHREAD_MUTEX_INITIALIZER;
static NSHashTable *contexts;
static MadeiraInterpolationSnapshot counters;
static char contextKey;
#define FLOW_MEMORY_LIMIT (32ull * 1024 * 1024)

@interface MadeiraFlowContext : NSObject
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) id<MTLComputePipelineState> match, midpoint;
@property(nonatomic, strong) id<MTLTexture> history, generated;
@property(nonatomic, strong) id<MTLBuffer> forward, backward, summary;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic) uint64_t epoch, version, accountedBytes;
@property(nonatomic) BOOL busy, valid, failed;
@property(nonatomic) double previousTime, lastNativeDeadline;
@end
@implementation MadeiraFlowContext
- (instancetype)init { if ((self=[super init])) _lock=[NSLock new]; return self; }
- (void)discard {
    if (_busy) return;
    _history=nil; _generated=nil; _forward=nil; _backward=nil; _summary=nil;
    _valid=NO; _previousTime=0; _lastNativeDeadline=0; _version++;
    if (_accountedBytes) { atomic_fetch_sub(&residentBytes,_accountedBytes); _accountedBytes=0; }
}
- (void)dealloc { if (_accountedBytes) atomic_fetch_sub(&residentBytes,_accountedBytes); }
@end

static void status(int value) {
    pthread_mutex_lock(&metricsLock); counters.status=value; pthread_mutex_unlock(&metricsLock);
}
int madeira_interpolation_supported(void) {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    return madeira_performance_renderer_available() && device && [device supportsFamily:MTLGPUFamilyApple4];
}
int madeira_interpolation_requested(void) {
    const char *remote=getenv("DXMT_REMOTE_METAL");
    return !(remote && *remote) && atomic_load(&requestedMode)>0;
}
void madeira_interpolation_snapshot(MadeiraInterpolationSnapshot *out) {
    if (!out) return;
    pthread_mutex_lock(&metricsLock); *out=counters; pthread_mutex_unlock(&metricsLock);
}
void madeira_interpolation_pressure(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        pthread_mutex_lock(&registryLock); NSArray *all=contexts.allObjects; pthread_mutex_unlock(&registryLock);
        for (MadeiraFlowContext *ctx in all) { [ctx.lock lock]; [ctx discard]; [ctx.lock unlock]; }
    });
}
void madeira_interpolation_configure(int mode) {
    mode=(mode==1 || mode==2) && madeira_interpolation_supported()?mode:0;
    atomic_store(&requestedMode,mode); atomic_store(&gateEnabled,0); atomic_store(&nativeFPS,0);
    atomic_fetch_add(&epoch,1);
    pthread_mutex_lock(&metricsLock); counters=(MadeiraInterpolationSnapshot){.status=mode?1:0}; pthread_mutex_unlock(&metricsLock);
    madeira_interpolation_pressure();
}
void madeira_interpolation_gate(int enabled, int fps, int reason) {
    enabled=!!enabled && madeira_interpolation_requested() && (fps==30 || fps==60);
    int changed=atomic_exchange(&gateEnabled,enabled)!=enabled;
    if (atomic_exchange(&nativeFPS,fps)!=fps) changed=1;
    if (changed) { atomic_fetch_add(&epoch,1); madeira_interpolation_pressure(); }
    if (!enabled) status(madeira_interpolation_requested()?reason:0);
}
static MadeiraFlowContext *context(CAMetalLayer *layer) {
    @synchronized(layer) {
        MadeiraFlowContext *ctx=objc_getAssociatedObject(layer,&contextKey);
        if (!ctx) {
            ctx=[MadeiraFlowContext new]; objc_setAssociatedObject(layer,&contextKey,ctx,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            pthread_mutex_lock(&registryLock);
            if (!contexts) contexts=[NSHashTable weakObjectsHashTable];
            [contexts addObject:ctx]; pthread_mutex_unlock(&registryLock);
        }
        return ctx;
    }
}
static BOOL reserveBytes(uint64_t bytes) {
    uint64_t old=atomic_load(&residentBytes);
    do { if (bytes>FLOW_MEMORY_LIMIT || old>FLOW_MEMORY_LIMIT-bytes) return NO; }
    while (!atomic_compare_exchange_weak(&residentBytes,&old,old+bytes));
    return YES;
}
static BOOL prepare(MadeiraFlowContext *ctx,id<MTLTexture> texture,uint64_t currentEpoch) {
    BOOL same=ctx.history && ctx.epoch==currentEpoch && ctx.history.device==texture.device &&
        ctx.history.width==texture.width && ctx.history.height==texture.height && ctx.history.pixelFormat==texture.pixelFormat;
    if (same) return YES;
    [ctx discard];
    if (ctx.epoch!=currentEpoch) { ctx.epoch=currentEpoch; ctx.failed=NO; }
    if (ctx.failed || [NSThread isMainThread]) return NO;
    id<MTLDevice> device=texture.device;
    if (!ctx.match || ctx.match.device!=device) {
        NSError *error=nil;
        MTLCompileOptions *options=[MTLCompileOptions new]; options.languageVersion=MTLLanguageVersion2_4;
        id<MTLLibrary> library=[device newLibraryWithSource:@(madeira_optical_flow_source) options:options error:&error];
        id<MTLFunction> match=[library newFunctionWithName:@"madeira_flow"], midpoint=[library newFunctionWithName:@"madeira_midpoint"];
        if (match && midpoint) {
            ctx.match=[device newComputePipelineStateWithFunction:match error:&error];
            ctx.midpoint=[device newComputePipelineStateWithFunction:midpoint error:&error];
        }
        if (!ctx.match || !ctx.midpoint) {
            ctx.failed=YES; fprintf(stderr,"[interpolation] optical-flow pipeline unavailable: %s\n",error.localizedDescription.UTF8String?:"missing kernel");
            return NO;
        }
    }
    NSUInteger tiles=((texture.width+15)/16)*((texture.height+15)/16), flowBytes=tiles*16;
    uint64_t bytes=texture.width*texture.height*8+flowBytes*2+16;
    if (!reserveBytes(bytes)) return NO;
    ctx.accountedBytes=bytes;
    MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:texture.pixelFormat width:texture.width height:texture.height mipmapped:NO];
    desc.storageMode=MTLStorageModePrivate; desc.hazardTrackingMode=MTLHazardTrackingModeTracked;
    desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
    ctx.history=[device newTextureWithDescriptor:desc]; ctx.generated=[device newTextureWithDescriptor:desc];
    ctx.forward=[device newBufferWithLength:flowBytes options:MTLResourceStorageModePrivate|MTLResourceHazardTrackingModeTracked];
    ctx.backward=[device newBufferWithLength:flowBytes options:MTLResourceStorageModePrivate|MTLResourceHazardTrackingModeTracked];
    ctx.summary=[device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    if (!ctx.history || !ctx.generated || !ctx.forward || !ctx.backward || !ctx.summary) { [ctx discard]; return NO; }
    return YES;
}
static BOOL copy(id<MTLCommandBuffer> buffer,id<MTLTexture> source,id<MTLTexture> target) {
    id<MTLBlitCommandEncoder> encoder=[buffer blitCommandEncoder];
    if (!encoder) return NO;
    [encoder copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(source.width,source.height,1) toTexture:target destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [encoder endEncoding]; return YES;
}
static void dispatch(id<MTLComputeCommandEncoder> encoder,id<MTLComputePipelineState> pipeline,NSUInteger width,NSUInteger height) {
    [encoder setComputePipelineState:pipeline];
    NSUInteger x=MIN((NSUInteger)8,pipeline.threadExecutionWidth),y=MIN((NSUInteger)8,pipeline.maxTotalThreadsPerThreadgroup/x);
    [encoder dispatchThreads:MTLSizeMake(width,height,1) threadsPerThreadgroup:MTLSizeMake(x,y,1)];
}
static BOOL encode(MadeiraFlowContext *ctx,id<MTLCommandBuffer> buffer,id<MTLTexture> current) {
    memset(ctx.summary.contents,0,16);
    id<MTLComputeCommandEncoder> encoder=[buffer computeCommandEncoder];
    if (!encoder) return NO;
    [encoder setTexture:ctx.history atIndex:0]; [encoder setTexture:current atIndex:1];
    [encoder setBuffer:ctx.forward offset:0 atIndex:0]; [encoder setBuffer:ctx.backward offset:0 atIndex:1];
    [encoder setBuffer:ctx.summary offset:0 atIndex:2];
    dispatch(encoder,ctx.match,(current.width+15)/16,(current.height+15)/16); [encoder endEncoding];
    encoder=[buffer computeCommandEncoder];
    if (!encoder) return NO;
    [encoder setTexture:ctx.history atIndex:0]; [encoder setTexture:current atIndex:1]; [encoder setTexture:ctx.generated atIndex:2];
    [encoder setBuffer:ctx.forward offset:0 atIndex:0]; [encoder setBuffer:ctx.backward offset:0 atIndex:1];
    dispatch(encoder,ctx.midpoint,current.width,current.height); [encoder endEncoding];
    return YES;
}
int madeira_interpolation_present(id<MTLCommandBuffer> buffer,id<CAMetalDrawable> drawable) {
    if (!atomic_load(&gateEnabled) || !madeira_interpolation_requested()) return 0;
    id<MTLTexture> color=drawable.texture; CAMetalLayer *layer=drawable.layer;
    if (!color || layer.wantsExtendedDynamicRangeContent || color.width>1920 || color.height>1440 ||
        color.width<320 || color.height<240 || color.sampleCount!=1 || color.textureType!=MTLTextureType2D ||
        !(color.usage&MTLTextureUsageShaderRead) ||
        (color.pixelFormat!=MTLPixelFormatBGRA8Unorm && color.pixelFormat!=MTLPixelFormatRGBA8Unorm)) { status(7); return 0; }
    MadeiraFlowContext *ctx=context(layer);
    [ctx.lock lock];
    if (ctx.busy) { ctx.valid=NO; ctx.version++; [ctx.lock unlock]; status(11); return 0; }
    uint64_t generation=atomic_load(&epoch);
    if (!prepare(ctx,color,generation)) { [ctx.lock unlock]; status(7); return 0; }
    int fps=atomic_load(&nativeFPS),mode=atomic_load(&requestedMode);
    if ((fps!=30 && fps!=60) || generation!=atomic_load(&epoch) || !atomic_load(&gateEnabled)) { [ctx.lock unlock]; return 0; }
    id<MTLCommandQueue> queue=buffer.commandQueue;
    double now=CACurrentMediaTime(),period=1.0/fps;
    BOOL pair=ctx.valid && ctx.queue==buffer.commandQueue && now-ctx.previousTime>=period*0.9 && now-ctx.previousTime<=period*1.1;
    if (!pair) ctx.lastNativeDeadline=0;
    ctx.busy=YES; uint64_t version=++ctx.version;
    ctx.queue=buffer.commandQueue; ctx.previousTime=now;
    [ctx.lock unlock];
    id<CAMetalDrawable> generated=nil;
    if (pair) {
        double start=CACurrentMediaTime(); generated=[layer nextDrawable];
        if (!generated || CACurrentMediaTime()-start>0.004 || generated.texture.width!=color.width ||
            generated.texture.height!=color.height || generated.texture.pixelFormat!=color.pixelFormat) { generated=nil; pair=NO; status(10); }
    }
    BOOL synthesized=pair && encode(ctx,buffer,color);
    BOOL historyCopied=copy(buffer,color,ctx.history);
    if (!historyCopied) synthesized=NO;
    if (synthesized) { pthread_mutex_lock(&metricsLock); counters.encoded++; pthread_mutex_unlock(&metricsLock); }
    else status(2);
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
        BOOL healthy=done.status==MTLCommandBufferStatusCompleted;
        [ctx.lock lock];
        ctx.valid=historyCopied && healthy && ctx.version==version && generation==atomic_load(&epoch);
        BOOL active=ctx.valid && atomic_load(&gateEnabled) && madeira_interpolation_requested();
        MadeiraInterpolationTimes times;
        const uint32_t *summary=ctx.summary.contents;
        BOOL confident=madeira_interpolation_confidence(summary[0],summary[1],summary[2],mode==2);
        double gpu=done.GPUEndTime-done.GPUStartTime;
        BOOL timely=done.GPUStartTime>0 && gpu>0 && gpu<period*(mode==2?0.35:0.45) &&
            madeira_interpolation_times(CACurrentMediaTime(),ctx.lastNativeDeadline,fps,&times);
        BOOL show=synthesized && active && confident && timely;
        if (!show) ctx.lastNativeDeadline=0;
        else ctx.lastNativeDeadline=times.native;
        [ctx.lock unlock];
        if (!synthesized) {
            // Warm history without changing the original native presentation.
            [ctx.lock lock]; ctx.busy=NO; if (!active) [ctx discard]; [ctx.lock unlock];
            return;
        }
        id<MTLCommandBuffer> presentation=[queue commandBuffer];
        if (presentation) {
            if (show && !copy(presentation,ctx.generated,generated.texture)) show=NO;
            if (show) {
                [generated addPresentedHandler:^(id<MTLDrawable> shown) {
                    if (shown.presentedTime<=0 || generation!=atomic_load(&epoch)) return;
                    pthread_mutex_lock(&metricsLock); counters.visible++; counters.visible_valid=1; pthread_mutex_unlock(&metricsLock);
                }];
                [presentation presentDrawable:generated atTime:times.generated];
                [presentation presentDrawable:drawable atTime:times.native];
            } else [presentation presentDrawable:drawable];
            [presentation addCompletedHandler:^(id<MTLCommandBuffer> retired) {
                if (retired.status!=MTLCommandBufferStatusCompleted) status(9);
                [ctx.lock lock]; ctx.busy=NO; if (!atomic_load(&gateEnabled) || generation!=atomic_load(&epoch)) [ctx discard]; [ctx.lock unlock];
            }];
            [presentation commit];
        } else {
            [drawable present]; show=NO;
            [ctx.lock lock]; ctx.busy=NO; [ctx discard]; [ctx.lock unlock];
        }
        if (generation==atomic_load(&epoch)) {
            pthread_mutex_lock(&metricsLock);
            counters.gpu_ms=healthy && gpu>0?gpu*1000:0;
            if (show) { counters.scheduled++; counters.status=3; counters.added_latency_ms=500.0/fps; }
            else { counters.skipped++; counters.status=!active?1:(!healthy?9:(!confident?8:10)); counters.added_latency_ms=0; }
            pthread_mutex_unlock(&metricsLock);
        }
    }];
    return synthesized; // Only the paired path takes ownership of native presentation.
}

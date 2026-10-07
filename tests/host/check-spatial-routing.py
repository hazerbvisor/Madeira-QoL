#!/usr/bin/env python3
"""Exercise production presentation bounds, memory reservations and GPU lease release.

Materialize the real native thunk overlay and check both guest ABI tables use its
texture boundary. Actual MetalFX images require an iOS GPU.
"""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
tests = r'''
#include "SpatialPresentationPolicy.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
static _Atomic uint64_t resident;
static void *compete(void *unused) {
    (void)unused;
    MadeiraSpatialSize size = {1280, 960, 1920, 1440};
    for (int i=0; i<10000; i++) {
        if (!madeira_spatial_reserve_bytes(&resident, size)) continue;
        assert(atomic_load(&resident) <= MADEIRA_SPATIAL_BYTES);
        atomic_fetch_sub(&resident, madeira_spatial_surface_bytes(size));
    }
    return 0;
}
int main(void) {
    MadeiraSpatialSize size;
    assert(madeira_spatial_size(768,576,1280,960,&size));
    assert(size.input_width==768 && size.input_height==576);
    assert(size.output_width==1280 && size.output_height==960);
    assert(madeira_spatial_size(960,540,1280,960,&size));
    assert(size.output_width==1280 && size.output_height==720);
    assert(!madeira_spatial_size(1280,960,1280,960,&size));
    assert(!madeira_spatial_size(2560,1920,1280,960,&size));
    assert(!madeira_spatial_size(0,576,1280,960,&size));
    assert(!madeira_spatial_size(NAN,576,1280,960,&size));
    assert(!madeira_spatial_size(INFINITY,576,1280,960,&size));
    assert(!madeira_spatial_size(8192,8192,1280,960,&size));
    assert(!madeira_spatial_size(32,32,1280,960,&size));
    assert(!madeira_spatial_size(768,576,1280,0,&size));
    assert(!madeira_spatial_size(768,576,8192,8192,&size));
    size=(MadeiraSpatialSize){4096,4096,4096,4096};
    assert(madeira_spatial_can_allocate(0,size));
    assert(!madeira_spatial_can_allocate(1,size));
    assert(madeira_spatial_reserve_bytes(&resident,size));
    assert(!madeira_spatial_reserve_bytes(&resident,size));
    atomic_fetch_sub(&resident,madeira_spatial_surface_bytes(size));
    pthread_t threads[8];
    for(int i=0;i<8;i++) pthread_create(&threads[i],0,compete,0);
    for(int i=0;i<8;i++) pthread_join(threads[i],0);
    assert(atomic_load(&resident)==0);
    MadeiraSpatialLease first,second;
    atomic_init(&first.finished,0);atomic_init(&second.finished,0);
    assert(madeira_spatial_finish_lease(&first)); // GPU completion returns slot
    assert(!madeira_spatial_finish_lease(&first)); // old drawable destruction cannot return a reused slot
    assert(madeira_spatial_finish_lease(&second)); // dropped, unsubmitted drawable
    assert(!madeira_spatial_finish_lease(&second));
    puts("PASS: aspect/output bounds, invalid sizes, concurrent global memory budget and idempotent GPU/drawable lease release");
}
'''
with tempfile.TemporaryDirectory() as directory:
    work=Path(directory); c=work/'routing.c'; c.write_text(tests)
    subprocess.run([os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra',
                    '-I'+str(root/'app/Madeira'),str(c),'-lm','-lpthread','-o',str(work/'routing')],check=True)
    subprocess.run([str(work/'routing')],check=True)
    overlay=work/'winemetal_unix.c'
    subprocess.run(['python3',str(root/'build/dxmt-ios/performance-overlay.py'),
                    str(root/'dxmt/src/winemetal/unix/winemetal_unix.c'),str(overlay)],check=True)
    text=overlay.read_text()
    for name in ['_MetalDrawable_texture','_MetalLayer_nextDrawable']:
        assert text.count('    &'+name+',')==2, name
    assert 'madeira_spatial_drawable_texture((id<CAMetalDrawable>)params->handle)' in text
    assert 'madeira_spatial_next_drawable((CAMetalLayer *)params->handle)' in text
    assert 'madeira_spatial_layer_requested_size(layer, &props->drawable_width, &props->drawable_height)' in text
    assert 'descriptor.colorAttachments[0].texture);' in text
    assert 'madeira_spatial_note_backbuffer(encoder, (id<MTLTexture>)body->texture, body->index);' in text
    bridge=(root/'app/Madeira/PerformanceBridge.m').read_text()
    assert bridge.count('madeira_spatial_finish_lease(')==2
    assert bridge.index('spatialFinish(buffer, drawable);') < bridge.index('if (targetFPS < 0) return NO;')
    assert 'newLibraryWithSource:' not in bridge
    assert 'newLibraryWithData:data' in bridge
    assert 'objc_setAssociatedObject(drawable, &spatialFrameKey, nil' in bridge
    print('PASS: unchanged x86_64/WoW64 ABI tables share the native texture bridge; legacy pacing completes the redirected image')

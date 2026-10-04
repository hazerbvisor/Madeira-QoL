#!/usr/bin/env python3
"""Run native/guest sizing admission and per-thread caller marking from production C."""
from pathlib import Path
import os, subprocess, tempfile
root=Path(__file__).resolve().parents[2]
source=(root/'app/Madeira/PerformanceBridge.m').read_text()
a=source.index('void madeira_spatial_native_props(')
b=source.index('int madeira_spatial_encode(',a)
fixture=r'''
#include <stdatomic.h>
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#define MIN(a,b) ((a)<(b)?(a):(b))
static _Atomic int spatialEnabled = 1, outputWidth = 1280, outputHeight = 960;
static _Thread_local unsigned nativePropsDepth;
'''
tests=r'''
static void *other_thread(void *unused) {
    assert(!madeira_spatial_native_props_active());
    double w=640,h=480;
    madeira_spatial_adjust_size(madeira_spatial_native_props_active(), &w, &h);
    assert(w==640 && h==480);
    return 0;
}
int main(void) {
    double w=640,h=480;
    madeira_spatial_adjust_size(0, &w, &h); assert(w==640 && h==480);
    madeira_spatial_native_props(1); madeira_spatial_native_props(1);
    assert(madeira_spatial_native_props_active());
    pthread_t thread; pthread_create(&thread,0,other_thread,0); pthread_join(thread,0);
    int before_main_hop = madeira_spatial_native_props_active();
    madeira_spatial_native_props(0); madeira_spatial_native_props(0);
    assert(!madeira_spatial_native_props_active());
    madeira_spatial_adjust_size(before_main_hop, &w, &h); assert(w==1280 && h==960);
    w=1560;h=720;madeira_spatial_adjust_size(1,&w,&h);assert(w==1280 && h==591);
    w=2560;h=1920;madeira_spatial_adjust_size(1,&w,&h);assert(w==1280 && h==960);
    w=0;h=480;madeira_spatial_adjust_size(1,&w,&h);assert(w==0 && h==480);
    w=NAN;h=480;madeira_spatial_adjust_size(1,&w,&h);assert(isnan(w) && h==480);
    atomic_store(&spatialEnabled,0);w=640;h=480;
    madeira_spatial_adjust_size(1,&w,&h);assert(w==640 && h==480);
    puts("PASS: guest drawable unchanged, native output sizing, nested/thread-isolated marker, main-hop capture and invalid/disabled fallback");
}
'''
with tempfile.TemporaryDirectory() as directory:
    work=Path(directory);c=work/'routing.c';c.write_text(fixture+source[a:b]+tests)
    subprocess.run([os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Wno-unused-parameter',str(c),'-lm','-lpthread','-o',str(work/'routing')],check=True)
    subprocess.run([str(work/'routing')],check=True)

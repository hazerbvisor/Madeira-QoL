#!/usr/bin/env python3
"""Add parent-owned performance hooks to pinned DXMT without editing its gitlink.

Exact anchors deliberately fail on upstream drift instead of silently disabling
features. The original renderer remains untouched; the builder compiles this copy.
"""
import pathlib
import sys

source, destination = map(pathlib.Path, sys.argv[1:])
text = source.read_text()

if source.name == 'dxmt_presenter.cpp':
    # Native and guest rendering now converge at the drawable texture bridge.
    # Preserve the original renderer's gamma, format conversion and MSAA resolve.
    text = text.replace('double width = layer_props_.drawable_width;', 'double width = drawable.texture().width();')
    text = text.replace('double height = layer_props_.drawable_height;', 'double height = drawable.texture().height();')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)
    sys.exit(0)

def once(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit(f'Performance hook anchor drift: {old[:80]!r}')
    text = text.replace(old, new, 1)

once('#import <Metal/Metal.h>', '#import <Metal/Metal.h>\n#include "PerformanceBridge.h"\nint madeira_dxmt_performance_hooks_v1(void) { return 1; }')
once('  int mode = g_madeira_vsync_mode;\n', '''  int mode = g_madeira_vsync_mode;
  if (madeira_performance_present((id<MTLCommandBuffer>)params->handle,
                                  (id<CAMetalDrawable>)params->arg, 0)) {
    madeira_log_present_cadence("performanceDeadline", 0);
    return STATUS_SUCCESS;
  }
''')
once('  madeira_log_present_cadence("presentDrawableAfterMinDuration", params->arg1);', '''  if (madeira_performance_present((id<MTLCommandBuffer>)params->handle,
                                  (id<CAMetalDrawable>)params->arg0, params->arg1)) {
    madeira_log_present_cadence("performanceDeadline", params->arg1);
    return STATUS_SUCCESS;
  }
  madeira_log_present_cadence("presentDrawableAfterMinDuration", params->arg1);''')
once('    layer.drawableSize = CGSizeMake(props->drawable_width, props->drawable_height);', '''    madeira_spatial_layer_configure(layer, props->drawable_width, props->drawable_height);
    layer.drawableSize = CGSizeMake(props->drawable_width, props->drawable_height);''')
once('  params->ret = (obj_handle_t)[(id<CAMetalDrawable>)params->handle texture];',
     '  params->ret = (obj_handle_t)madeira_spatial_drawable_texture((id<CAMetalDrawable>)params->handle);')
once('  params->ret = (obj_handle_t)[(CAMetalLayer *)params->handle nextDrawable];',
     '  params->ret = (obj_handle_t)madeira_spatial_next_drawable((CAMetalLayer *)params->handle);')
once('    if (enabled) props->contents_scale = 1.0;',
     '    if (enabled || madeira_spatial_requested() || madeira_interpolation_requested()) props->contents_scale = 1.0;')
once('  props->drawable_width = layer.drawableSize.width;', '''  props->drawable_width = layer.drawableSize.width;
  // A guest Presenter must inherit its own viewport dimensions, not the host's
  // enlarged output. This also applies to secondary swapchains on the same layer.
  madeira_spatial_layer_requested_size(layer, &props->drawable_width, &props->drawable_height);''')
once('  params->ret = (obj_handle_t)[(id<MTLCommandBuffer>)params->handle renderCommandEncoderWithDescriptor:descriptor];', '''  params->ret = (obj_handle_t)[(id<MTLCommandBuffer>)params->handle renderCommandEncoderWithDescriptor:descriptor];
  madeira_spatial_track_encoder((id<MTLRenderCommandEncoder>)params->ret,
      (id<MTLCommandBuffer>)params->handle, descriptor.colorAttachments[0].texture);''')
once('      [encoder setFragmentTexture:(id<MTLTexture>)body->texture atIndex:body->index];', '''      [encoder setFragmentTexture:(id<MTLTexture>)body->texture atIndex:body->index];
      madeira_spatial_note_backbuffer(encoder, (id<MTLTexture>)body->texture, body->index);''')

for name in ['_MTLDevice_newComputePipelineState', '_MTLDevice_newRenderPipelineState', '_MTLDevice_newRenderPipelineStateVD']:
    start = text.index('static NTSTATUS\n' + name + '(')
    end = text.index('\nstatic NTSTATUS', start + 1)
    function = text[start:end]
    old = '  MTLPipelineOption options ='
    assert function.count(old) == 1
    function = function.replace(old, '''  if (!info->fail_on_binary_archive_miss && !info->num_binary_archives_for_lookup)
    madeira_pipeline_attach((id<MTLDevice>)params->device, descriptor);
  double madeira_compile_start = CACurrentMediaTime();
  MTLPipelineOption options =''')
    old = '  params->ret_error = (obj_handle_t)err;'
    assert function.count(old) == 1
    function = function.replace(old, '''  madeira_performance_note_pipeline((CACurrentMediaTime() - madeira_compile_start) * 1000);
  if (params->ret_pso && !err)
    madeira_pipeline_record((id<MTLDevice>)params->device, descriptor);
  params->ret_error = (obj_handle_t)err;''')
    text = text[:start] + function + text[end:]

destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(text)

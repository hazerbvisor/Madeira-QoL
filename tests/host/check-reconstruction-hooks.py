#!/usr/bin/env python3
"""Test the real provider boundary using fake textures; no images are generated."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[2]
hooks=(root/'app/Madeira/ReconstructionRendererHooks.swift').read_text().replace('import Metal','')
mock=r'''
import Foundation
protocol MTLDevice { var registryID: UInt64 { get } }
protocol MTLTexture { var width: Int { get }; var height: Int { get }; var sampleCount: Int { get }; var device: any MTLDevice { get } }
protocol MTLCommandBuffer { var device: any MTLDevice { get } }
struct Device: MTLDevice { var registryID: UInt64 = 1 }
struct Texture: MTLTexture { var width = 1280; var height = 720; var sampleCount = 1; var device: any MTLDevice = Device() }
struct Buffer: MTLCommandBuffer { var device: any MTLDevice = Device() }
var generated = 0
func madeira_performance_note_generated_encode() { generated += 1 }
final class Provider: MadeiraInterpolationProvider {
    var supportedInputs: ReconstructionInputs = .interpolation
    var accept = true, calls = 0
    func encode(packet: ReconstructionFramePacket, at time: Double, commandBuffer: any MTLCommandBuffer, output: any MTLTexture) -> Bool {
        calls += 1; return accept
    }
}
'''
tests=r'''
let color = Texture(), stream = UUID(), backend = Provider()
func packet(_ reset: Bool = false, _ depth: Texture = Texture()) -> ReconstructionFramePacket {
    ReconstructionFramePacket(streamID: stream, nativeFrameID: 1, previousColor: color, color: color,
        motion: color, depth: depth, jitter: SIMD2<Float>(0,0), exposure: 1,
        previousNativeTime: 1, nativeTime: 1.033, resetHistory: reset)
}
var signals = PerformanceSignals(frameMS: 33, p95MS: 35, gpuMS: 10, cpuPercent: nil, pipelineMS: nil)
func encode(_ p: ReconstructionFramePacket = packet(), _ out: Texture = Texture(), _ time: Double = 1.016) -> Bool {
    ReconstructionRendererHooks.encode(mode: .double, packet: p, nativeFPS: 30, signals: signals,
        time: time, commandBuffer: Buffer(), output: out)
}
assert(!encode() && generated == 0) // no registered backend
ReconstructionRendererHooks.register(backend)
assert(encode() && backend.calls == 1 && generated == 1)
backend.accept = false
assert(!encode() && generated == 1) // failure does not count as a generated encode
backend.accept = true
assert(!encode(packet(true))) // history reset: no coherent pair
assert(!encode(packet(false, Texture(width: 640))))
assert(!encode(packet(), Texture(sampleCount: 4)))
assert(!encode(packet(), Texture(device: Device(registryID: 2))))
assert(!encode(packet(), Texture(), 1.05))
signals.memory = .critical; assert(!encode())
signals.memory = .normal; backend.supportedInputs = [.color]; assert(!encode())
ReconstructionRendererHooks.register(nil)
assert(!encode() && generated == 1)
print("PASS: missing provider, coherent frame history, dimensions/devices, sample count, time range, pressure and successful-encode-only accounting")
'''
with tempfile.TemporaryDirectory() as directory:
    work=Path(directory);main=work/'main.swift';main.write_text(mock+hooks+tests)
    sources=['PerformancePolicy.swift','AdaptivePerformancePolicy.swift','FrameReconstructionPolicy.swift']
    subprocess.run([os.environ.get('SWIFTC','swiftc'),*[str(root/'app/Madeira'/x) for x in sources],str(main),'-o',str(work/'hooks')],check=True)
    subprocess.run([str(work/'hooks')],check=True)

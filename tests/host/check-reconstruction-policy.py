#!/usr/bin/env python3
"""No synthesis: test production rejection gates for an optional future backend."""
import os, subprocess, tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as directory:
    work=Path(directory); main=work/'main.swift'
    main.write_text(r'''
import Foundation
var signal = PerformanceSignals(frameMS: 33.3, p95MS: 35, gpuMS: 10, cpuPercent: nil, pipelineMS: nil)
func check(_ mode: FrameInterpolationMode = .double, _ backend: Bool = true, _ inputs: ReconstructionInputs = .interpolation, _ fps: Double = 30) -> ReconstructionEligibility {
    FrameReconstructionPolicy.eligibility(mode: mode, backend: backend, inputs: inputs, nativeFPS: fps, signals: signal)
}
assert(check(.off) == .disabled)
assert(check(.double, false) == .missingBackend)
assert(check(.double, true, [.color]) == .missingInputs)
assert(check(.double, true, .interpolation, 29.9) == .lowNativeRate)
assert(check() == .allowed && check(.auto) == .allowed)
signal.p95MS = 60; assert(check() == .unstablePacing)
signal.p95MS = 35; signal.gpuMS = 20; assert(check() == .noHeadroom)
signal.gpuMS = nil; assert(check() == .noHeadroom)
signal.gpuMS = 10; signal.memory = .critical; assert(check() == .pressure)
signal.memory = .normal; signal.thermalSerious = true; assert(check() == .pressure)
signal.thermalSerious = false; signal.powerConstrained = true; assert(check() == .pressure)
signal.powerConstrained = false; signal.frameMS = .nan; assert(check() == .unstablePacing)
print("PASS: disabled/missing backend or inputs, low native rate, unstable pacing, missing GPU data and memory/thermal/power gates")
''')
    sources=['PerformancePolicy.swift','AdaptivePerformancePolicy.swift','FrameReconstructionPolicy.swift']
    subprocess.run([os.environ.get('SWIFTC','swiftc'),*[str(root/'app/Madeira'/x) for x in sources],str(main),'-o',str(work/'gates')],check=True)
    subprocess.run([str(work/'gates')],check=True)

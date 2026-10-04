#!/usr/bin/env python3
"""Check production adaptive policies with sustained, noisy and invalid signals."""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as directory:
    work=Path(directory)
    source=work/'main.swift'
    source.write_text(r'''
import Foundation
var slow = PerformanceSignals(frameMS: 42, p95MS: 50, gpuMS: 36, cpuPercent: 40, pipelineMS: nil)
assert(slow.bottleneck(targetFPS: 30) == .gpu)
var cpu = slow; cpu.gpuMS = 8; cpu.cpuPercent = 90
assert(cpu.bottleneck(targetFPS: 30) == .cpu)
var pipeline = slow; pipeline.pipelineMS = 90
assert(pipeline.bottleneck(targetFPS: 30) == .shader)
var pressured = slow; pressured.memory = .critical
assert(pressured.bottleneck(targetFPS: 30) == .memory)
var thermal = slow; thermal.thermalSerious = true
assert(thermal.bottleneck(targetFPS: 30) == .thermal)
var scale = AdaptiveRenderScalePolicy()
func advice(_ signals: PerformanceSignals, _ time: Double, _ current: Double = 0.8) -> Double? {
    scale.recommendation(signals: signals, now: time, targetFPS: 30, current: current, minimum: 0.5, maximum: 1)
}
assert(advice(slow, 0) == nil && advice(slow, 2) == nil)
assert(abs(advice(slow, 3)! - 0.77) < 0.0001)
assert(advice(slow, 4, 0.77) == nil)
assert(abs(advice(slow, 8, 0.77)! - 0.74) < 0.0001)
let fast = PerformanceSignals(frameMS: 33.3, p95MS: 34, gpuMS: 10, cpuPercent: 20, pipelineMS: nil)
assert(advice(fast, 9) == nil && advice(fast, 20) == nil)
assert(abs(advice(fast, 21)! - 0.83) < 0.0001)
assert(advice(cpu, 30) == nil && advice(cpu, 40) == nil)
assert(advice(pressured, 41) == nil && advice(thermal, 42) == nil)
var invalid = fast; invalid.p95MS = .nan
assert(advice(invalid, 50) == nil && advice(invalid, 80) == nil)
scale = AdaptiveRenderScalePolicy()
assert(advice(slow, 90, 0.5) == nil && advice(slow, 94, 0.5) == nil)
scale = AdaptiveRenderScalePolicy()
// A short spike followed by headroom cannot be mistaken for sustained overload.
assert(advice(slow, 100) == nil && advice(fast, 102) == nil && advice(slow, 103) == nil)
assert(advice(slow, 105) == nil)
var fps = AutoFPSPolicy()
assert(fps.target(signals: thermal, now: 0, current: 120, requested: 120) == 30)
assert(fps.target(signals: fast, now: 1, current: 30, requested: 120) == nil)
assert(fps.target(signals: fast, now: 30, current: 30, requested: 120) == nil)
assert(fps.target(signals: fast, now: 31, current: 30, requested: 120) == 40)
assert(fps.target(signals: pressured, now: 32, current: 40, requested: 120) == 30)
assert(fps.target(signals: slow, now: 90, current: 30, requested: 120) == nil)
assert(fps.target(signals: slow, now: 190, current: 30, requested: 120) == nil)
var eco = fast; eco.powerConstrained = true
assert(fps.target(signals: eco, now: 191, current: 60, requested: 60) == 30)
print("PASS: bottlenecks, three/12-second scale hysteresis, five-second cooldown, bounds, missing data and pressure/recovery caps")
''')
    subprocess.run([os.environ.get('SWIFTC','swiftc'),str(root/'app/Madeira/PerformancePolicy.swift'),str(root/'app/Madeira/AdaptivePerformancePolicy.swift'),str(source),'-o',str(work/'policy')],check=True)
    subprocess.run([str(work/'policy')],check=True)

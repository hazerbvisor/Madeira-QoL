#!/usr/bin/env python3
"""Run production sampling and pressure coordination with OS/renderer signals stubbed."""
from pathlib import Path
import os, subprocess, tempfile
root=Path(__file__).resolve().parents[2]
source=(root/'app/Madeira/PerformanceRuntime.swift').read_text()
def method(start,end):
    return source[source.index(start):source.index(end,source.index(start))].replace('private func','func')
refresh=method('    func refresh()', '    private var memoryPressure:')
conditions=method('    private func conditionsChanged()', '    private func cpuSeconds()')
cap=source[source.index('    private func pauseInterpolation('):].rsplit('\n}',1)[0].replace('private func','func')
stubs=r'''
import Foundation
struct Entry { var id = UUID(); var performanceUpgrade: PerformanceProfile? }
final class LibraryModel {
    static let shared = LibraryModel()
    var launching = false, menu = false, performance = false
    var activeEntry: Entry?
}
struct MadeiraPerformanceSnapshot { var native_frames: UInt64 = 100; var presented_frames: UInt64 = 80; var pipeline_requests: UInt64 = 10; var generated_encoded_frames: UInt64 = 0; var generated_scheduled_frames: UInt64 = 0; var generated_presented_frames: UInt64 = 0 }
var telemetry = -1, capValue = -1, cacheLevels: [Int32] = [], sampled = 0
var interpolationGate = -1, interpolationReason = -1
func madeira_interpolation_gate(_ enabled: Int32, _ fps: Int32, _ reason: Int32) { interpolationGate = Int(enabled); interpolationReason = Int(reason) }
func madeira_performance_set_telemetry(_ value: Int32) { telemetry = Int(value) }
func madeira_performance_set_cap(_ value: Int32) { capValue = Int(value) }
func madeira_performance_snapshot(_ value: inout MadeiraPerformanceSnapshot) { value = MadeiraPerformanceSnapshot() }
func madeira_performance_cache_pressure(_ value: Int32) { cacheLevels.append(value) }
func CACurrentMediaTime() -> Double { 100 }
struct ProcessInfo { static let processInfo = ProcessInfo(); var isLowPowerModeEnabled: Bool { false } }
enum AmbientArtwork { static var cleared = 0; static func clear() { cleared += 1 } }
enum ProMotionIntent { static func apply(cap: Int) {} }
final class Runtime {
    var entryID: UUID? = UUID()
    var active = true, thermalSerious = false
    var profile = PerformanceProfile()
    var timer: Timer?
    var previousNative: UInt64 = 0, previousVisible: UInt64 = 0, previousPipelines: UInt64 = 0
    var previousGenerated: UInt64 = 0, previousScheduled: UInt64 = 0, previousGeneratedVisible: UInt64 = 0
    var interpolationPolicy = OpticalFlowAdmission()
    var previousTime = 0.0, previousCPU: Double?
    var scalePolicy = AdaptiveRenderScalePolicy(), fpsPolicy = AutoFPSPolicy()
    var currentCap = 60, lastCachePressure = -1
    var memoryPressure: RuntimePressure = .normal
    func cpuSeconds() -> Double? { 3 }
    func sample() { sampled += 1 }
'''
tests=r'''
}
let runtime = Runtime(), library = LibraryModel.shared
runtime.refresh()
assert(runtime.timer == nil && telemetry == 0)
library.performance = true; runtime.refresh()
assert(runtime.timer != nil && telemetry == 1 && runtime.previousNative == 100)
library.menu = true; runtime.refresh()
assert(runtime.timer == nil && telemetry == 0)
library.menu = false; library.performance = false
runtime.profile.automaticPerformance = true; runtime.refresh()
assert(runtime.timer != nil && telemetry == 1 && capValue == 60)
runtime.active = false; runtime.refresh()
assert(runtime.timer == nil && telemetry == 0)
runtime.active = true; library.launching = true; runtime.refresh()
assert(runtime.timer == nil && telemetry == 0)
// Pressure handling must still release optional state while telemetry is hidden.
runtime.memoryPressure = .critical
runtime.refresh()
assert(runtime.timer == nil && cacheLevels.last == 2 && AmbientArtwork.cleared > 0)
assert(runtime.currentCap == 30 && capValue == 30)
runtime.memoryPressure = .normal; runtime.thermalSerious = true
runtime.refresh(); assert(cacheLevels.last == 1)
runtime.thermalSerious = false; runtime.refresh(); assert(cacheLevels.last == 0)
runtime.profile.automaticPerformance = false; library.launching = false
runtime.refresh(); assert(runtime.timer == nil && telemetry == 0)
runtime.profile.interpolation = .double; runtime.refresh(); assert(runtime.timer != nil && telemetry == 1)
library.menu = true; runtime.refresh(); assert(runtime.timer == nil && interpolationGate == 0 && interpolationReason == 1)
library.menu = false; runtime.memoryPressure = .critical; runtime.refresh(); assert(interpolationGate == 0 && interpolationReason == 4)
print("PASS: all optional modes off stop sampling; interpolation alone samples; menu/launch/background and pressure withdraw generation")
'''
with tempfile.TemporaryDirectory() as directory:
    work=Path(directory); main=work/'main.swift';main.write_text(stubs+refresh+conditions+cap+tests)
    subprocess.run([os.environ.get('SWIFTC','swiftc'),str(root/'app/Madeira/PerformancePolicy.swift'),str(root/'app/Madeira/AdaptivePerformancePolicy.swift'),str(main),'-o',str(work/'lifecycle')],check=True)
    subprocess.run([str(work/'lifecycle')],check=True)

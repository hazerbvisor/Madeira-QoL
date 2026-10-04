import Foundation
import Combine
import Darwin
import UIKit
import QuartzCore

struct PerformanceReadout {
    var nativeFPS: Double?
    var visibleFPS: Double?
    var generatedEncodedFPS = 0.0, generatedScheduledFPS = 0.0
    var generatedVisibleFPS: Double?
    var interpolationStatus = 0, interpolationLatencyMS = 0.0
    var frameMS: Double = 0, p95MS: Double = 0, maxMS: Double = 0
    var gpuMS: Double?, cpuPercent: Double?, memoryMB: Int?, availableMB: Int?
    var pressure: RuntimePressure = .normal
    var thermal = "Unknown"
    var bottleneck: PerformanceBottleneck = .unknown
    var internalWidth = 0, internalHeight = 0, outputWidth = 0, outputHeight = 0
    var presentationWidth = 0, presentationHeight = 0
    var spatialActive = false
    var spatialStatus = 0
    var activeCap = -1
    var stalls: UInt64 = 0
    var decision: String?
}

/// Main-queue session coordinator. Measurements stay in a separate observable
/// object so a one-second HUD tick does not invalidate the whole library.
/// Pressure/thermal notifications remain active even when telemetry is hidden;
/// the sample timer and renderer callbacks run for HUD, Auto or interpolation safety.
final class PerformanceRuntime: ObservableObject, @unchecked Sendable {
    static let shared = PerformanceRuntime()
    @Published private(set) var readout = PerformanceReadout()
    private var profile = PerformanceProfile()
    private var entryID: UUID?
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []
    private var active = true
    private var pressure: RuntimePressure = .normal
    private var warningUntil = 0.0
    private var previousTime = 0.0, previousCPU: Double?
    private var previousNative: UInt64 = 0, previousVisible: UInt64 = 0, previousPipelines: UInt64 = 0
    private var previousGenerated: UInt64 = 0, previousScheduled: UInt64 = 0, previousGeneratedVisible: UInt64 = 0
    private var interpolationPolicy = OpticalFlowAdmission()
    private var scalePolicy = AdaptiveRenderScalePolicy()
    private var fpsPolicy = AutoFPSPolicy()
    private var currentCap = -1
    private var requestedFPS = 30
    private var lastCachePressure = -1

    func begin(_ entry: LibraryEntry) {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        entryID = entry.id; profile = entry.performanceUpgrade ?? PerformanceProfile()
        requestedFPS = PerformanceProfile.fpsCaps.filter { $0 > 0 && $0 <= profile.autoRequestedFPS && $0 <= ProMotionIntent.panelMaxFPS }.max() ?? 30
        currentCap = profile.automaticPerformance ? min(profile.lastAutoFPS ?? requestedFPS, requestedFPS) : profile.initialFPSCap
        let mode = entry.spatialCompatible ? profile.interpolation : .off
        madeira_interpolation_configure(mode == .double ? 1 : mode == .auto ? 2 : 0)
        readout = PerformanceReadout(); active = true
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.conditionsChanged()
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.warningUntil = CACurrentMediaTime() + 30
            self.conditionsChanged()
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.active = false; self?.refresh()
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.active = true; self?.refresh()
        })
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.pressureSource else { return }
            self.pressure = source.data.contains(.critical) ? .critical : source.data.contains(.warning) ? .warning : .normal
            self.conditionsChanged()
        }
        pressureSource = source; source.resume()
        refresh()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.invalidate(); timer = nil
        pressureSource?.cancel(); pressureSource = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll(); entryID = nil
        pressure = .normal; warningUntil = 0; previousTime = 0; previousCPU = nil
        scalePolicy = AdaptiveRenderScalePolicy(); fpsPolicy = AutoFPSPolicy(); lastCachePressure = -1
        if interpolationPolicy.enabled { ProMotionIntent.apply(cap: currentCap) }
        madeira_interpolation_configure(0); interpolationPolicy.reset()
        madeira_performance_set_telemetry(0)
        madeira_performance_cache_pressure(0)
    }

    func manualPacingSelected() {
        pauseInterpolation(reason: 1)
        profile.automaticPerformance = false; currentCap = -1; refresh()
    }

    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard entryID != nil else { return }
        let library = LibraryModel.shared
        if profile.automaticPerformance { madeira_performance_set_cap(Int32(currentCap)) }
        let shouldSample = active && !library.launching && !library.menu && (library.performance || profile.automaticPerformance || profile.interpolation != .off)
        madeira_performance_set_telemetry(shouldSample ? 1 : 0)
        if shouldSample && timer == nil {
            var snapshot = MadeiraPerformanceSnapshot(); madeira_performance_snapshot(&snapshot)
            previousNative = snapshot.native_frames; previousVisible = snapshot.presented_frames
            previousGenerated = snapshot.generated_encoded_frames
            previousScheduled = snapshot.generated_scheduled_frames; previousGeneratedVisible = snapshot.generated_presented_frames
            previousPipelines = snapshot.pipeline_requests; previousTime = CACurrentMediaTime(); previousCPU = cpuSeconds()
            let value = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
            value.tolerance = 0.1; RunLoop.main.add(value, forMode: .common); timer = value
        } else if !shouldSample {
            timer?.invalidate(); timer = nil; scalePolicy.reset()
            fpsPolicy = AutoFPSPolicy() // recovery needs uninterrupted gameplay samples
            pauseInterpolation(reason: 1)
        }
        conditionsChanged()
    }

    private var memoryPressure: RuntimePressure {
        pressure == .critical ? .critical : (pressure == .warning || CACurrentMediaTime() < warningUntil ? .warning : .normal)
    }
    private var thermalSerious: Bool {
        ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
    }
    private func thermalLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
    private func conditionsChanged() {
        guard entryID != nil else { return }
        let memory = memoryPressure
        let level = memory == .critical ? 2 : (memory != .normal || thermalSerious ? 1 : 0)
        if level != lastCachePressure {
            lastCachePressure = level; madeira_performance_cache_pressure(Int32(level))
            if level > 0 { MainActor.assumeIsolated { AmbientArtwork.clear() } }
        }
        if level > 0 || ProcessInfo.processInfo.isLowPowerModeEnabled { pauseInterpolation(reason: 4) }
        if profile.automaticPerformance && (level > 0 || ProcessInfo.processInfo.isLowPowerModeEnabled) && currentCap > 30 {
            changeCap(30, reason: "30 FPS for memory, thermal or power pressure")
        }
    }
    private func cpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private func footprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
    }
    private func sample() {
        guard entryID != nil else { return }
        conditionsChanged()
        var snapshot = MadeiraPerformanceSnapshot(); madeira_performance_snapshot(&snapshot)
        let now = CACurrentMediaTime(), dt = now - previousTime, cpu = cpuSeconds()
        guard dt > 0 else { return }
        let cpuPercent = cpu.flatMap { current in previousCPU.map { max(0, (current - $0) / dt * 100) } }
        let native = snapshot.native_frames >= previousNative ? Double(snapshot.native_frames - previousNative) / dt : 0
        let visible = snapshot.presented_valid != 0 && snapshot.presented_frames >= previousVisible ? Double(snapshot.presented_frames - previousVisible) / dt : nil
        let gpu = snapshot.gpu_valid != 0 ? snapshot.gpu_ms : nil
        let generated = snapshot.generated_encoded_frames >= previousGenerated ? Double(snapshot.generated_encoded_frames - previousGenerated) / dt : 0
        let scheduled = snapshot.generated_scheduled_frames >= previousScheduled ? Double(snapshot.generated_scheduled_frames - previousScheduled) / dt : 0
        let generatedVisible = snapshot.generated_presented_valid != 0 && snapshot.generated_presented_frames >= previousGeneratedVisible ? Double(snapshot.generated_presented_frames - previousGeneratedVisible) / dt : nil
        let pipeline = snapshot.pipeline_requests > previousPipelines ? snapshot.pipeline_ms : nil
        previousTime = now; previousCPU = cpu; previousNative = snapshot.native_frames
        previousVisible = snapshot.presented_frames; previousPipelines = snapshot.pipeline_requests
        previousGenerated = snapshot.generated_encoded_frames
        previousScheduled = snapshot.generated_scheduled_frames; previousGeneratedVisible = snapshot.generated_presented_frames
        let signals = PerformanceSignals(frameMS: snapshot.mean_ms, p95MS: snapshot.p95_ms, gpuMS: gpu,
            cpuPercent: cpuPercent, pipelineMS: pipeline, memory: memoryPressure, thermalSerious: thermalSerious,
            powerConstrained: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if profile.automaticPerformance {
            if let target = fpsPolicy.target(signals: signals, now: now, current: currentCap, requested: requestedFPS) {
                changeCap(target, reason: "Recovered gradually to \(target) FPS with measured headroom")
            }
            if profile.fxMode != .off, LibraryModel.shared.activeEntry?.spatialCompatible == true,
               snapshot.spatial_active != 0, madeira_spatial_supported() != 0,
               snapshot.internal_width > 0, snapshot.internal_height > 0,
               snapshot.internal_width < snapshot.output_width, snapshot.internal_height < snapshot.output_height,
               let scale = scalePolicy.recommendation(signals: signals, now: now, targetFPS: max(currentCap, 30),
                    current: profile.nextLaunchScale ?? profile.renderScale, minimum: profile.minimumScale, maximum: profile.maximumScale) {
                profile.nextLaunchScale = scale
                profile.lastAutoDecision = "Recommended \(Int((scale * 100).rounded()))% scale for next launch; live render targets unchanged"
                persistDecision()
            }
        }
        let wasEnabled = interpolationPolicy.enabled
        let reason = interpolationPolicy.update(mode: profile.interpolation, cap: currentCap, panelFPS: ProMotionIntent.panelMaxFPS,
            nativeFPS: native, meanMS: snapshot.mean_ms, p95MS: snapshot.p95_ms, gpuMS: gpu,
            constrained: memoryPressure != .normal || thermalSerious || ProcessInfo.processInfo.isLowPowerModeEnabled, now: now)
        madeira_interpolation_gate(interpolationPolicy.enabled ? 1 : 0, Int32(currentCap), Int32(reason))
        if wasEnabled != interpolationPolicy.enabled { ProMotionIntent.apply(cap: interpolationPolicy.enabled ? currentCap * 2 : currentCap) }
        var value = PerformanceReadout()
        value.nativeFPS = madeira_performance_renderer_available() != 0 ? native : nil; value.visibleFPS = visible
        value.generatedEncodedFPS = generated; value.generatedScheduledFPS = scheduled; value.generatedVisibleFPS = generatedVisible
        value.interpolationStatus = Int(snapshot.interpolation_status); value.interpolationLatencyMS = snapshot.interpolation_latency_ms
        value.frameMS = snapshot.mean_ms; value.p95MS = snapshot.p95_ms; value.maxMS = snapshot.max_ms
        value.cpuPercent = cpuPercent; value.gpuMS = gpu; value.memoryMB = footprintMB()
        value.availableMB = Int(madeira_available_memory() / 1_048_576)
        value.pressure = memoryPressure; value.thermal = thermalLabel()
        value.bottleneck = signals.bottleneck(targetFPS: max(currentCap, 30))
        value.internalWidth = Int(snapshot.internal_width); value.internalHeight = Int(snapshot.internal_height)
        value.outputWidth = Int(snapshot.output_width); value.outputHeight = Int(snapshot.output_height)
        value.presentationWidth = Int(snapshot.presentation_width); value.presentationHeight = Int(snapshot.presentation_height)
        value.spatialActive = snapshot.spatial_active != 0; value.spatialStatus = Int(snapshot.spatial_status)
        value.activeCap = Int(snapshot.effective_cap)
        value.stalls = snapshot.stalls; value.decision = profile.lastAutoDecision
        readout = value
    }
    private func pauseInterpolation(reason: Int) {
        let wasEnabled = interpolationPolicy.enabled
        interpolationPolicy.reset(); madeira_interpolation_gate(0, Int32(currentCap), Int32(reason))
        if wasEnabled { ProMotionIntent.apply(cap: currentCap) }
    }
    private func changeCap(_ target: Int, reason: String) {
        pauseInterpolation(reason: 1)
        currentCap = target; madeira_performance_set_cap(Int32(target)); ProMotionIntent.apply(cap: target)
        profile.lastAutoFPS = target; profile.lastAutoDecision = reason; persistDecision()
    }
    private func persistDecision() {
        // Existing profile saves on menu close / session finish persist this.
        // Sampling never writes the library to disk or alters compatibility knobs.
        guard profile.automaticPerformance, LibraryModel.shared.activeEntry?.id == entryID else { return }
        LibraryModel.shared.activeEntry?.performanceUpgrade = profile
    }
}

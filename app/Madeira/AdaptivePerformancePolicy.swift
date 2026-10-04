import Foundation

enum RuntimePressure: String, Codable {
    case normal, warning, critical
}

enum PerformanceBottleneck: String {
    case unknown = "Mixed / unknown"
    case cpu = "CPU/FEX (estimate)"
    case gpu = "GPU/render (estimate)"
    case shader = "Pipeline preparation (estimate)"
    case memory = "Memory pressure"
    case thermal = "Thermal risk"
}

struct PerformanceSignals {
    var frameMS: Double
    var p95MS: Double
    var gpuMS: Double?
    var cpuPercent: Double?
    var pipelineMS: Double?
    var memory: RuntimePressure = .normal
    var thermalSerious = false
    var powerConstrained = false

    func bottleneck(targetFPS: Int) -> PerformanceBottleneck {
        if memory != .normal { return .memory }
        if thermalSerious { return .thermal }
        let budget = 1000 / Double(max(targetFPS, 1))
        if let pipelineMS, pipelineMS > budget { return .shader }
        guard frameMS.isFinite, frameMS > budget * 1.1 else { return .unknown }
        if let gpuMS, gpuMS.isFinite, gpuMS > budget * 0.85 { return .gpu }
        if let cpuPercent, let gpuMS, cpuPercent >= 75, gpuMS < budget * 0.6 { return .cpu }
        return .unknown
    }
}

/// Produces conservative scale advice from real measurements. It deliberately
/// has no renderer-resize side effect: live internal resolution is unsupported
/// until a game/renderer exposes a cooperative resize contract.
struct AdaptiveRenderScalePolicy {
    private var overloadedSince: Double?
    private var headroomSince: Double?
    private var lastChange = -Double.infinity

    mutating func reset() { overloadedSince = nil; headroomSince = nil }
    mutating func recommendation(signals: PerformanceSignals, now: Double, targetFPS: Int,
                                 current: Double, minimum: Double, maximum: Double) -> Double? {
        guard now.isFinite, current.isFinite, minimum.isFinite, maximum.isFinite,
              minimum >= 0.5, maximum <= 1, minimum <= maximum, targetFPS > 0,
              signals.memory == .normal, !signals.thermalSerious, let gpu = signals.gpuMS,
              gpu.isFinite, gpu > 0, signals.frameMS.isFinite, signals.frameMS > 0,
              signals.p95MS.isFinite, signals.p95MS > 0,
              current >= minimum, current <= maximum else {
            reset(); return nil
        }
        let budget = 1000 / Double(targetFPS)
        let overloaded = signals.bottleneck(targetFPS: targetFPS) == .gpu
        let headroom = gpu < budget * 0.55 && signals.frameMS <= budget * 1.04 && signals.p95MS <= budget * 1.1
        if overloaded { overloadedSince = overloadedSince ?? now } else { overloadedSince = nil }
        if headroom { headroomSince = headroomSince ?? now } else { headroomSince = nil }
        guard now - lastChange >= 5 else { return nil }
        let delta: Double
        if let since = overloadedSince, now - since >= 3 { delta = -0.03 }
        else if let since = headroomSince, now - since >= 12 { delta = 0.03 }
        else { return nil }
        let value = min(max(current + delta, minimum), maximum)
        guard abs(value - current) >= 0.001 else { return nil }
        lastChange = now; reset(); return value
    }
}

struct AutoFPSPolicy {
    private var lastChange = -Double.infinity
    private var recoverySince: Double?

    mutating func target(signals: PerformanceSignals, now: Double, current: Int, requested: Int) -> Int? {
        guard now.isFinite, current >= 30, requested >= 30 else { return nil }
        if signals.memory != .normal || signals.thermalSerious || signals.powerConstrained {
            recoverySince = nil
            if current > 30 { lastChange = now; return 30 }
            return nil
        }
        guard current < requested else { recoverySince = nil; return nil }
        let budget = 1000 / Double(current)
        guard signals.frameMS.isFinite, signals.frameMS > 0, signals.frameMS <= budget * 1.1,
              signals.p95MS.isFinite, signals.p95MS > 0, signals.p95MS <= budget * 1.25,
              let gpu = signals.gpuMS, gpu.isFinite, gpu > 0, gpu < budget * 0.8 else {
            recoverySince = nil; return nil
        }
        recoverySince = recoverySince ?? now
        guard now - (recoverySince ?? now) >= 30, now - lastChange >= 30 else { return nil }
        lastChange = now; recoverySince = nil
        return PerformanceProfile.fpsCaps.filter { $0 > current && $0 <= requested }.min()
    }
}

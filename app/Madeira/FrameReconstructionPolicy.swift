import Foundation

struct ReconstructionInputs: OptionSet, Sendable {
    let rawValue: Int
    static let color = Self(rawValue: 1 << 0)
    static let previousColor = Self(rawValue: 1 << 1)
    static let motion = Self(rawValue: 1 << 2)
    static let depth = Self(rawValue: 1 << 3)
    static let jitter = Self(rawValue: 1 << 4)
    static let exposure = Self(rawValue: 1 << 5)
    static let coherentHistory = Self(rawValue: 1 << 6)
    static let temporal: Self = [.color, .motion, .depth, .jitter, .exposure, .coherentHistory]
    static let interpolation: Self = [.temporal, .previousColor]
}

enum ReconstructionEligibility: Equatable {
    case allowed, disabled, missingBackend, missingInputs, lowNativeRate, unstablePacing, noHeadroom, pressure
    var explanation: String {
        switch self {
        case .allowed: return "Eligible"
        case .disabled: return "Off"
        case .missingBackend: return "No validated reconstruction backend"
        case .missingInputs: return "Motion, depth, jitter and coherent history unavailable"
        case .lowNativeRate: return "Native rate below 30 FPS"
        case .unstablePacing: return "Native frame pacing is unstable"
        case .noHeadroom: return "Insufficient measured GPU headroom"
        case .pressure: return "Memory, thermal or power pressure"
        }
    }
}

/// Admission policy only; it never synthesizes a frame or advertises a backend.
/// The common DXMT present boundary supplies color, but not the temporal inputs.
struct FrameReconstructionPolicy {
    static func eligibility(mode: FrameInterpolationMode, backend: Bool, inputs: ReconstructionInputs,
                            nativeFPS: Double, signals: PerformanceSignals) -> ReconstructionEligibility {
        guard mode != .off else { return .disabled }
        guard backend else { return .missingBackend }
        guard inputs.isSuperset(of: .interpolation) else { return .missingInputs }
        guard signals.memory == .normal, !signals.thermalSerious, !signals.powerConstrained else { return .pressure }
        guard nativeFPS.isFinite, nativeFPS >= 30 else { return .lowNativeRate }
        guard signals.frameMS.isFinite, signals.frameMS > 0, signals.p95MS.isFinite,
              signals.p95MS > 0, signals.p95MS <= signals.frameMS * 1.2 else { return .unstablePacing }
        guard let gpu = signals.gpuMS, gpu.isFinite, gpu > 0, gpu < 1000 / nativeFPS * 0.45 else { return .noHeadroom }
        return .allowed
    }
}

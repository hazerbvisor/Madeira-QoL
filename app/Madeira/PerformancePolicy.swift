import Foundation

enum MadeiraFXMode: String, Codable, CaseIterable {
    case off, quality, balanced, performance, auto
    var label: String { rawValue.capitalized }
    var recommendedScale: Double {
        switch self {
        case .off: return 1
        case .quality: return 0.85
        case .balanced: return 0.72
        case .performance: return 0.60
        case .auto: return 0.77
        }
    }
}

enum MouseCaptureBehavior: String, Codable, CaseIterable {
    case automatic, manual, disabled
}

enum FrameInterpolationMode: String, Codable, CaseIterable {
    case off, double, auto
}

/// Optional LibraryEntry field: old libraries keep their existing pacing,
/// resolution, input and compatibility defaults until a player changes a knob.
struct PerformanceProfile: Codable, Equatable {
    var fpsCap: Int?
    var fxMode: MadeiraFXMode = .off
    var renderScale: Double = 1
    var dynamicResolution = false
    var minimumScale: Double = 0.5
    var maximumScale: Double = 1
    var automaticPerformance = false
    var fullscreen = true
    var mouseCapture: MouseCaptureBehavior = .automatic
    var mouseSensitivity: Double?
    var interpolation: FrameInterpolationMode = .off

    static let fpsCaps = [30, 40, 60, 90, 120, 0]

    init() {}
    enum CodingKeys: String, CodingKey {
        case fpsCap, fxMode, renderScale, dynamicResolution, minimumScale, maximumScale
        case automaticPerformance, fullscreen, mouseCapture, mouseSensitivity, interpolation
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fpsCap = try? c.decode(Int.self, forKey: .fpsCap)
        if let cap = fpsCap, !Self.fpsCaps.contains(cap) { fpsCap = nil }
        fxMode = (try? c.decode(MadeiraFXMode.self, forKey: .fxMode)) ?? .off
        renderScale = (try? c.decode(Double.self, forKey: .renderScale)) ?? 1
        minimumScale = (try? c.decode(Double.self, forKey: .minimumScale)) ?? 0.5
        maximumScale = (try? c.decode(Double.self, forKey: .maximumScale)) ?? 1
        dynamicResolution = (try? c.decode(Bool.self, forKey: .dynamicResolution)) ?? false
        automaticPerformance = (try? c.decode(Bool.self, forKey: .automaticPerformance)) ?? false
        fullscreen = (try? c.decode(Bool.self, forKey: .fullscreen)) ?? true
        mouseCapture = (try? c.decode(MouseCaptureBehavior.self, forKey: .mouseCapture)) ?? .automatic
        mouseSensitivity = try? c.decode(Double.self, forKey: .mouseSensitivity)
        interpolation = (try? c.decode(FrameInterpolationMode.self, forKey: .interpolation)) ?? .off
        normalize()
    }
    mutating func normalize() {
        if let cap = fpsCap, !Self.fpsCaps.contains(cap) { fpsCap = nil }
        minimumScale = minimumScale.isFinite ? min(max(minimumScale, 0.5), 1) : 0.5
        maximumScale = maximumScale.isFinite ? min(max(maximumScale, minimumScale), 1) : 1
        renderScale = renderScale.isFinite ? min(max(renderScale, minimumScale), maximumScale) : 1
        if let sensitivity = mouseSensitivity {
            mouseSensitivity = sensitivity.isFinite ? min(max(sensitivity, 0.1), 8) : nil
        }
    }
    func internalResolution(outputWidth: Int, outputHeight: Int) -> (width: Int, height: Int) {
        let scale = fxMode == .off ? 1 : renderScale
        return (max(320, Int((Double(outputWidth) * scale).rounded())),
                max(240, Int((Double(outputHeight) * scale).rounded())))
    }
}

import SwiftUI
import UIKit

struct PerformanceProfileSettings: View {
    @Binding var entry: LibraryEntry
    private var profile: Binding<PerformanceProfile> {
        Binding(get: { entry.performanceUpgrade ?? PerformanceProfile() }, set: {
            var value = $0; value.normalize(); entry.performanceUpgrade = value
        })
    }
    var body: some View {
        Section("Frame delivery") {
            Toggle("Auto performance", isOn: profile.automaticPerformance)
                .disabled(madeira_performance_renderer_available() == 0)
            Picker("Precise FPS cap", selection: Binding(get: { profile.wrappedValue.fpsCap ?? -1 }, set: {
                var value = profile.wrappedValue; value.fpsCap = $0 < 0 ? nil : $0; profile.wrappedValue = value
            })) {
                Text(profile.wrappedValue.automaticPerformance ? "Auto default (30 FPS)" : "Use existing FPS limit").tag(-1)
                ForEach(PerformanceProfile.fpsCaps.filter { $0 <= UIScreen.main.maximumFramesPerSecond }, id: \.self) { cap in
                    Text(cap == 0 ? (profile.wrappedValue.automaticPerformance ? "Unlimited request (Auto uses 30 FPS)" : "Unlimited") : "\(cap) FPS").tag(cap)
                }
            }.disabled(madeira_performance_renderer_available() == 0)
            Text("Uses absolute frame deadlines and respects slower game-requested pacing. Display refresh and thermal limits may reduce visible FPS.")
                .font(.caption).foregroundStyle(.secondary)
            if profile.wrappedValue.automaticPerformance {
                Text("Auto targets the selected cap, or 30 FPS when no fixed cap is selected. It reduces to 30 under memory, thermal or power pressure and recovers gradually only with measured GPU headroom.")
                    .font(.caption).foregroundStyle(.secondary)
                if let decision = profile.wrappedValue.lastAutoDecision { Text(decision).font(.caption) }
            }
        }
        Section("Fullscreen and mouse") {
            Toggle("Fullscreen presentation", isOn: profile.fullscreen)
            Picker("Mouse capture", selection: profile.mouseCapture) {
                Text("Follow game cursor").tag(MouseCaptureBehavior.automatic)
                Text("Manual (Ctrl+Alt+P)").tag(MouseCaptureBehavior.manual)
                Text("Disabled").tag(MouseCaptureBehavior.disabled)
            }
            Slider(value: Binding(get: { profile.wrappedValue.mouseSensitivity ?? InputSettings.shared.sensMouse }, set: {
                var value = profile.wrappedValue; value.mouseSensitivity = $0; profile.wrappedValue = value
            }), in: 0.1...8) { Text("Mouse sensitivity") }
            Text(String(format: "Mouse sensitivity: %.2f", profile.wrappedValue.mouseSensitivity ?? InputSettings.shared.sensMouse))
                .font(.caption).foregroundStyle(.secondary)
            Button("Use default mouse sensitivity") {
                var value = profile.wrappedValue; value.mouseSensitivity = nil; profile.wrappedValue = value
            }
            Text("Capture releases when you open Madeira menus, edit touch controls, leave the game, or background the app. Pointer lock requires a raw mouse stream and a fullscreen iPad scene.")
                .font(.caption).foregroundStyle(.secondary)
        }
        MadeiraFXSettings(profile: profile, outputResolution: entry.resolution, compatibilityIssue: entry.spatialCompatibilityIssue)
        RendererCacheSettings(entry: entry)
    }
}

struct MadeiraFXSettings: View {
    @Binding var profile: PerformanceProfile
    var outputResolution: String
    var compatibilityIssue: String?
    private var compatible: Bool { compatibilityIssue == nil }
    private var supported: Bool { compatible && madeira_spatial_supported() != 0 }
    var body: some View {
        Section("MadeiraFX") {
            Picker("Game renderer", selection: $profile.fxRenderer) {
                ForEach(MadeiraFXRenderer.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("Select the renderer you use in-game if Auto detect cannot identify it. Choose DirectX 11 mode in ETS2. Effects activate only when local DXMT renders frames; changes apply at the next launch.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Spatial preset", selection: Binding(get: { profile.fxMode }, set: {
                profile.fxMode = $0; profile.renderScale = $0.recommendedScale; profile.nextLaunchScale = nil; profile.normalize()
                if $0 == .auto { profile.automaticPerformance = true }
            })) {
                ForEach(MadeiraFXMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }.disabled(!supported)
            if supported && profile.fxMode != .off {
                if profile.minimumScale < profile.maximumScale {
                    Slider(value: Binding(get: { profile.renderScale }, set: { profile.renderScale = $0; profile.nextLaunchScale = nil }), in: profile.minimumScale...profile.maximumScale) { Text("Internal render scale") }
                }
                Text("Requested internal: \(internalResolution) · Output target: \(outputResolution.replacingOccurrences(of: "x", with: "×")) · Scale setting: \(Int(profile.requestedRenderScale * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
                Text("The game must honor the lower session resolution. Actual dimensions and active upscaling appear in diagnostics. Changes apply at the next launch.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Minimum monitor dimensions can raise the effective scale to preserve unusual aspect ratios.")
                    .font(.caption).foregroundStyle(.secondary)
                if profile.automaticPerformance {
                    Slider(value: Binding(get: { profile.minimumScale }, set: { profile.minimumScale = $0; profile.normalize() }), in: 0.5...1) { Text("Minimum recommended scale") }
                    if profile.minimumScale < 1 {
                        Slider(value: Binding(get: { profile.maximumScale }, set: { profile.maximumScale = $0; profile.normalize() }), in: profile.minimumScale...1) { Text("Maximum recommended scale") }
                    }
                    Text("Next-launch recommendation range: \(Int(profile.minimumScale * 100))–\(Int(profile.maximumScale * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                    if let scale = profile.nextLaunchScale {
                        Text("Next launch: \(Int((scale * 100).rounded()))% · Current game resources are unchanged.").font(.caption)
                    }
                }
            } else if !supported {
                Text(spatialUnavailableReason)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if compatible {
                Text("Choose Direct3D 9 or 11 in the game if it offers multiple renderers. MadeiraFX activates only on the local DXMT presentation path.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Frame interpolation", selection: Binding(get: { profile.interpolation }, set: {
                profile.interpolation = $0
                if $0 != .off && profile.fpsCap != 30 && profile.fpsCap != 60 { profile.fpsCap = 30 }
            })) {
                Text("Off").tag(FrameInterpolationMode.off)
                Text("2× (experimental)").tag(FrameInterpolationMode.double)
                Text("Auto (experimental)").tag(FrameInterpolationMode.auto)
            }.disabled(!compatible || madeira_interpolation_supported() == 0)
            Text("Color-based optical flow generates a midpoint between rendered frames. Requires stable native 30/60 FPS, a 60/120 Hz display, GPU headroom and SDR output up to 1920×1440. Adds about half a native frame of display delay and may produce motion artifacts. Auto uses stricter quality and headroom gates. Changes apply at the next launch.")
                .font(.caption).foregroundStyle(.secondary)
            Text("MetalFX temporal reconstruction remains unavailable: the game does not supply motion vectors, depth and camera jitter.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Live dynamic internal resolution requires game support. Auto can recommend a scale for the next launch; it does not resize the game’s live render targets.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var spatialUnavailableReason: String {
        if let compatibilityIssue { return compatibilityIssue }
        if madeira_performance_renderer_available() == 0 { return "Local DXMT effects are unavailable in this app build. Install the latest PR #2 app and keep Remote Metal off." }
        return "This device or OS does not report MetalFX Spatial support."
    }
    private var internalResolution: String {
        let size = outputResolution.split(separator: "x").compactMap { Int($0) }
        guard size.count == 2 else { return "Unknown" }
        let result = profile.internalResolution(outputWidth: size[0], outputHeight: size[1])
        return "\(result.width)×\(result.height)"
    }
}

struct RendererCacheSettings: View {
    var entry: LibraryEntry? = nil
    @ObservedObject private var library = LibraryModel.shared
    @State private var working = false
    @State private var message: String?
    var body: some View {
        Section("Renderer caches") {
            Button(working ? "Clearing…" : "Clear \(entry == nil ? "all renderer" : "this game’s renderer") caches", role: .destructive) {
                working = true
                RendererCaches.clear(entry) { message = $0; working = false }
            }.disabled(working || library.current != nil)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("Compiled shaders and public Metal pipeline archives are reused between launches. Close the game before clearing caches. Persistent FEX translated-code reuse is unavailable in this runtime.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

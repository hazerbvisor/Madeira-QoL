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
            Picker("Precise FPS cap", selection: Binding(get: { profile.wrappedValue.fpsCap ?? -1 }, set: {
                var value = profile.wrappedValue; value.fpsCap = $0 < 0 ? nil : $0; profile.wrappedValue = value
            })) {
                Text("Use existing FPS limit").tag(-1)
                ForEach(PerformanceProfile.fpsCaps.filter { $0 <= UIScreen.main.maximumFramesPerSecond }, id: \.self) { cap in
                    Text(cap == 0 ? "Unlimited" : "\(cap) FPS").tag(cap)
                }
            }.disabled(madeira_performance_renderer_available() == 0)
            Text("Uses absolute frame deadlines and respects slower game-requested pacing. Display refresh and thermal limits may reduce visible FPS.")
                .font(.caption).foregroundStyle(.secondary)
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
        RendererCacheSettings(entry: entry)
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

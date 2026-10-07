import SwiftUI
import UIKit

struct LibraryMetrics: View {
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var runtime = PerformanceRuntime.shared
    @State private var battery = -1
    private var value: PerformanceReadout { runtime.readout }

    var body: some View {
        Text(lines.joined(separator: "\n"))
            .font(.caption.monospacedDigit().weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
            .onAppear {
                UIDevice.current.isBatteryMonitoringEnabled = library.overlayFields.contains("Battery")
                readBattery()
            }
            .onChange(of: library.overlayFields) { _, fields in
                UIDevice.current.isBatteryMonitoringEnabled = fields.contains("Battery"); readBattery()
            }
            .onDisappear { UIDevice.current.isBatteryMonitoringEnabled = false }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in readBattery() }
    }
    private func readBattery() {
        let level = UIDevice.current.batteryLevel
        battery = level < 0 ? -1 : Int(level * 100)
    }
    private var lines: [String] {
        let fields = library.overlayFields
        var lines: [String] = []
        if fields.contains("FPS") {
            lines.append(value.nativeFPS.map { String(format: "Native submissions: %.0f/s (estimate)", $0) } ?? "Native submissions: unavailable")
            lines.append(value.visibleFPS.map { String(format: "Native visible: %.0f FPS", $0) } ?? "Native visible FPS: unavailable")
            if (library.activeEntry?.performanceUpgrade?.interpolation ?? .off) != .off {
                lines.append(String(format: "Generated: %.0f encodes/s · %.0f scheduled/s", value.generatedEncodedFPS, value.generatedScheduledFPS))
                lines.append(value.generatedVisibleFPS.map { String(format: "Generated visible: %.0f FPS", $0) } ?? "Generated visible FPS: unavailable")
            }
        }
        if fields.contains("Frame time") {
            lines.append(value.frameMS > 0 ? String(format: "Submit intervals: %.1f avg · %.1f p95 · %.1f max ms", value.frameMS, value.p95MS, value.maxMS) : "Submit intervals: unavailable")
        }
        if fields.contains("Graphics") {
            let dimensions = value.internalWidth > 0 ? "Backbuffer \(value.internalWidth)×\(value.internalHeight) → \(value.outputWidth)×\(value.outputHeight)"
                : (value.outputWidth > 0 ? "Internal: unavailable · Output \(value.outputWidth)×\(value.outputHeight)" : "Render dimensions: unavailable")
            let scale = value.outputWidth > 0 && value.internalWidth > 0 ? String(format: " · %.0f%% actual", Double(value.internalWidth) / Double(value.outputWidth) * 100) : ""
            let requested = library.activeEntry?.performanceUpgrade?.fxMode ?? .off
            let reasons = [2: "Renderer scale fallback", 3: "Paused for pressure", 4: "Format/device unsupported",
                           5: "No compatible lower resolution", 6: "Storage/scaler unavailable"]
            let state = value.spatialActive ? "Spatial active" : (requested == .off ? "Off" : (reasons[value.spatialStatus] ?? "Original blit (fallback)"))
            lines.append(dimensions + scale)
            if value.presentationWidth > 0 && (value.presentationWidth != value.internalWidth || value.presentationHeight != value.internalHeight) {
                lines.append("Present input: \(value.presentationWidth)×\(value.presentationHeight) · Game backbuffer differs")
            }
            lines.append("MadeiraFX \(requested.label): \(state)")
            let interpolationReasons = [0: "Off", 1: "Waiting for stable samples", 2: "Warming history", 3: "2× active (experimental)",
                4: "Paused for pressure/power", 5: "Needs 30/60 FPS cap and 60/120 Hz display",
                6: library.activeEntry?.performanceUpgrade?.interpolation == .auto ? "Unstable native pacing" : "Waiting for native timing",
                7: "Format/device/storage unsupported", 8: "Motion confidence too low", 9: "Insufficient GPU headroom",
                10: "Missed presentation window", 11: "Previous frame still in flight"]
            lines.append("Interpolation: \(interpolationReasons[value.interpolationStatus] ?? "Unavailable")")
            if value.interpolationStatus == 3 { lines.append(String(format: "Added display delay: ~%.1f ms", value.interpolationLatencyMS)) }
        }
        if fields.contains("CPU/GPU") {
            let cpu = value.cpuPercent.map { String(format: "CPU %.0f%% (100%% = one core)", $0) } ?? "CPU unavailable"
            let gpu = value.gpuMS.map { String(format: "GPU %.1f ms (command buffer)", $0) } ?? "GPU unavailable"
            lines.append(cpu + " · " + gpu)
            lines.append(value.bottleneck.rawValue + " · Stalls: \(value.stalls)")
        }
        if fields.contains("RAM") {
            lines.append((value.memoryMB.map { "RAM \($0) MB" } ?? "RAM unavailable") + (value.availableMB.map { " · Available \($0) MB" } ?? ""))
        }
        if fields.contains("Pressure") { lines.append("Memory: \(value.pressure.rawValue) · Thermal: \(value.thermal)") }
        if fields.contains("FPS cap") {
            if madeira_performance_renderer_available() == 0 { lines.append("Precise FPS cap: unavailable for this renderer") }
            else { lines.append(value.activeCap < 0 ? "FPS cap: existing renderer mode" : value.activeCap == 0 ? "FPS cap: unlimited" : "FPS cap: \(value.activeCap)") }
            if let decision = value.decision { lines.append(decision) }
        }
        if fields.contains("Battery"), battery >= 0 { lines.append("Battery \(battery)%") }
        return lines.isEmpty ? ["Performance HUD: choose fields in Session"] : lines
    }
}

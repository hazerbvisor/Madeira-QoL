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
            let generated = value.generatedEncodedFPS > 0 ? String(format: "Generated encodes: %.0f/s (not visible FPS)", value.generatedEncodedFPS) : "Generated: off"
            lines.append((value.visibleFPS.map { String(format: "Visible: %.0f FPS", $0) } ?? "Visible FPS: unavailable") + " · " + generated)
        }
        if fields.contains("Frame time") {
            lines.append(value.frameMS > 0 ? String(format: "Submit intervals: %.1f avg · %.1f p95 · %.1f max ms", value.frameMS, value.p95MS, value.maxMS) : "Submit intervals: unavailable")
        }
        if fields.contains("Graphics") {
            let dimensions = value.internalWidth > 0 ? "\(value.internalWidth)×\(value.internalHeight) → \(value.outputWidth)×\(value.outputHeight)" : "Resolution: awaiting renderer"
            let scale = value.outputWidth > 0 && value.internalWidth > 0 ? String(format: " · %.0f%% actual", Double(value.internalWidth) / Double(value.outputWidth) * 100) : ""
            let requested = library.activeEntry?.performanceUpgrade?.fxMode ?? .off
            let state = value.spatialActive ? "Spatial active" : (requested == .off ? "Off" : "Original blit (fallback)")
            lines.append(dimensions + scale)
            lines.append("MadeiraFX \(requested.label): \(state) · Interpolation: off")
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

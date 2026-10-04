import Foundation
import Metal

/// An opt-in future renderer integration must supply one coherent native frame
/// pair. A guessed motion/depth texture or unrelated camera jitter is invalid.
struct ReconstructionFramePacket {
    let streamID: UUID // history must be isolated per swapchain/stream
    let nativeFrameID: UInt64
    let previousColor: any MTLTexture
    let color: any MTLTexture
    let motion: any MTLTexture
    let depth: any MTLTexture
    let jitter: SIMD2<Float>
    let exposure: Float
    let previousNativeTime: Double
    let nativeTime: Double
    let resetHistory: Bool

    var coherent: Bool {
        let textures = [previousColor, color, motion, depth]
        return nativeFrameID > 0 && nativeTime.isFinite && previousNativeTime.isFinite
            && previousNativeTime > 0 && nativeTime > previousNativeTime
            && jitter.x.isFinite && jitter.y.isFinite && exposure.isFinite && exposure > 0
            && !resetHistory && textures.allSatisfy {
                $0.width == color.width && $0.height == color.height && $0.sampleCount == 1
                    && $0.device.registryID == color.device.registryID
            }
    }
}

/// A real provider must encode an intermediate frame into the supplied command
/// buffer/output and report success. It owns thread safety/synchronization/history/latency
/// validation. Registering a provider alone never turns interpolation on.
protocol MadeiraInterpolationProvider: AnyObject {
    var supportedInputs: ReconstructionInputs { get }
    func encode(packet: ReconstructionFramePacket, at time: Double,
                commandBuffer: any MTLCommandBuffer, output: any MTLTexture) -> Bool
}

enum ReconstructionRendererHooks {
    private static let lock = NSLock()
    private static var provider: (any MadeiraInterpolationProvider)?

    /// No production provider is registered: current DXMT lacks the packet's
    /// motion/depth/jitter/history. This is the extension point for a validated
    /// game/renderer integration; no frame generation is fabricated here.
    static func register(_ value: (any MadeiraInterpolationProvider)?) {
        lock.lock(); provider = value; lock.unlock()
    }
    static func encode(mode: FrameInterpolationMode, packet: ReconstructionFramePacket,
                       nativeFPS: Double, signals: PerformanceSignals, time: Double,
                       commandBuffer: any MTLCommandBuffer, output: any MTLTexture) -> Bool {
        lock.lock(); let backend = provider; lock.unlock()
        guard let backend, packet.coherent, time.isFinite,
              time > packet.previousNativeTime, time < packet.nativeTime,
              output.device.registryID == packet.color.device.registryID,
              commandBuffer.device.registryID == packet.color.device.registryID,
              output.width == packet.color.width, output.height == packet.color.height,
              output.sampleCount == 1,
              FrameReconstructionPolicy.eligibility(mode: mode, backend: true, inputs: backend.supportedInputs,
                   nativeFPS: nativeFPS, signals: signals) == .allowed else { return false }
        let encoded = backend.encode(packet: packet, at: time, commandBuffer: commandBuffer, output: output)
        if encoded { madeira_performance_note_generated_encode() }
        // Encoding is not onscreen presentation. A future caller must provide
        // a separate generated-frame schedule/latency budget and visible-frame
        // accounting; it must not route these frames through the native counter.
        return encoded
    }
}

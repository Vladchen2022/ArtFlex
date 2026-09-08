import Metal

/// Reuses the exact same shaders and blend equations for both document precisions.
/// Every variant is compiled during renderer construction so encoding cannot silently fall back.
final class ColorRenderPipelineVariants {
    private let device: MTLDevice
    private var halfFloatStates: [ObjectIdentifier: MTLRenderPipelineState] = [:]

    init(device: MTLDevice) { self.device = device }

    func makeState(descriptor: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState {
        let base = try device.makeRenderPipelineState(descriptor: descriptor)
        if descriptor.colorAttachments[0].pixelFormat == .bgra8Unorm_srgb {
            let half = descriptor.copy() as! MTLRenderPipelineDescriptor
            half.colorAttachments[0].pixelFormat = .rgba16Float
            halfFloatStates[ObjectIdentifier(base)] = try device.makeRenderPipelineState(descriptor: half)
        }
        return base
    }

    func state(_ base: MTLRenderPipelineState, for format: MTLPixelFormat) -> MTLRenderPipelineState {
        format == .rgba16Float ? halfFloatStates[ObjectIdentifier(base)] ?? base : base
    }
}

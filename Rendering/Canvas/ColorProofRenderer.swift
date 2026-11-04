import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders

/// ColorSync's native conversion kernels simulate an RGB output profile. The bounded
/// intermediate represents the output device gamut, then is converted back for display.
final class ColorProofRenderer {
    private let toProof: MPSImageConversion
    private let fromProof: MPSImageConversion
    private let presenter: StageOneCanvasPresenter
    private let metal: MetalDeviceContext
    private var proof: MTLTexture?
    private var display: MTLTexture?

    init(profile: ManagedRGBProfile, metal: MetalDeviceContext) throws {
        let target = try ManagedColorTransform.colorSpace(profile)
        guard let canonical = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let forward = CGColorConversionInfo(src: canonical, dst: target),
              let backward = CGColorConversionInfo(src: target, dst: canonical) else {
            throw CanvasResourceError(message: "ColorSync 无法创建此 ICC 校样转换")
        }
        self.metal = metal
        toProof = MPSImageConversion(device: metal.device, srcAlpha: .premultiplied, destAlpha: .premultiplied,
            backgroundColor: nil, conversionInfo: forward)
        fromProof = MPSImageConversion(device: metal.device, srcAlpha: .premultiplied, destAlpha: .premultiplied,
            backgroundColor: nil, conversionInfo: backward)
        presenter = try StageOneCanvasPresenter(device: metal.device)
    }

    func encode(source: MTLTexture, into pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) throws {
        guard source.pixelFormat == .rgba16Float else { throw CanvasResourceError(message: "校样需要线性浮点显示表面") }
        if proof?.width != source.width || proof?.height != source.height {
            proof = nil; display = nil
            let reservation = try metal.workingResourceBudget.reserve(bytes: source.width * source.height * 16,
                residentBytes: metal.device.currentAllocatedSize)
            defer { withExtendedLifetime(reservation) {} }
            func make(_ format: MTLPixelFormat) -> MTLTexture? {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: source.width, height: source.height, mipmapped: false)
                descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                return metal.device.makeTexture(descriptor: descriptor)
            }
            proof = make(.rgba16Unorm); display = make(.rgba16Float)
        }
        guard let proof, let display else { throw CanvasResourceError(message: "校样显示所需内存不足") }
        toProof.encode(commandBuffer: command, sourceTexture: source, destinationTexture: proof)
        fromProof.encode(commandBuffer: command, sourceTexture: proof, destinationTexture: display)
        guard presenter.encode(layerInputs: [.init(texture: display, opacity: 1)], samplingMode: .nearest,
            into: pass, commandBuffer: command) else { throw CanvasResourceError(message: "校样显示失败") }
    }
}

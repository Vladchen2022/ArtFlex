import Metal

final class MetalDeviceContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard
            let device,
            let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
    }
}

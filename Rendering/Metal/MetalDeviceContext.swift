import Foundation
import Metal

final class MetalDeviceContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let workingResourceBudget: WorkingResourceBudget

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard
            let device,
            let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        let recommended = device.recommendedMaxWorkingSetSize
        let available = recommended > 0 ? recommended : ProcessInfo.processInfo.physicalMemory / 2
        self.workingResourceBudget = WorkingResourceBudget(maximumBytes:
            Int(min(UInt64(Int.max), available / 4 * 3)))
    }
}

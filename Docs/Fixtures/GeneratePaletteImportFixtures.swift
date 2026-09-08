// Generates synthetic images for visible UI acceptance; does not exercise ArtFlex internals.
// Usage: swift Docs/Fixtures/GeneratePaletteImportFixtures.swift <existing-output-directory>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func rgb(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])!
}
func image(_ name: String, width: Int, height: Int, draw: (CGContext) -> Void) throws {
    try autoreleasepool {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        let url = output.appendingPathComponent(name + ".png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        print(url.path)
    }
}
try image("01-黑白红绿蓝", width: 1000, height: 400) { context in
    for (i, color) in [[0.0,0,0], [1,1,1], [1,0,0], [0,1,0], [0,0,1]].enumerated() {
        context.setFillColor(rgb(color[0], color[1], color[2]))
        context.fill(CGRect(x: i * 200, y: 0, width: 200, height: 400))
    }
}
try image("02-透明底青色", width: 512, height: 512) { context in
    context.setFillColor(rgb(0, 1, 1))
    context.fill(CGRect(x: 128, y: 128, width: 256, height: 256))
}
try image("03-全透明", width: 512, height: 512) { _ in }
try image("04-单像素棕色", width: 1, height: 1) { context in
    context.setFillColor(rgb(0.6, 0.3, 0.1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
}
try Data("This is intentionally not a PNG image.\n".utf8).write(to: output.appendingPathComponent("05-损坏图片.png"))
try image("08-五级灰阶", width: 1000, height: 400) { context in
    for i in 0..<5 {
        let value = Double(i) / 4
        context.setFillColor(rgb(value, value, value))
        context.fill(CGRect(x: i * 200, y: 0, width: 200, height: 400))
    }
}
if CommandLine.arguments.contains("--small-only") { exit(0) }
try image("06-大图20000x16000", width: 20000, height: 16000) { context in
    for row in 0..<100 {
        for column in 0..<100 {
            context.setFillColor(rgb(Double(column) / 99, Double(row) / 99, Double((row + column) % 100) / 99))
            context.fill(CGRect(x: column * 200, y: row * 160, width: 200, height: 160))
        }
    }
}

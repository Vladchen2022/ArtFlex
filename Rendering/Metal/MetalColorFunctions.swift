enum MetalColorFunctions {
    /// Matches LinearPremultipliedColor and the brush shader. Render targets expect linear RGB.
    static let source = """
    float3 artflexSrgbToLinear(float3 color) {
        float3 v = abs(color);
        return sign(color) * select(pow((v + 0.055) / 1.055, float3(2.4)), v / 12.92, v <= 0.04045);
    }
    """
}

// Generate the two linear-primary matrices from the platform's calibrated spaces once.
// This keeps wide-color artistic adjustments in a bounded P3 domain without hand-tuned
// channel compensation. Existing in-gamut sRGB inputs retain their established formulas.
import CoreGraphics
extension MetalColorFunctions {
    static let gamutSource: String = {
        let srgb = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let p3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        func matrix(from source: CGColorSpace, to target: CGColorSpace) -> String {
            let columns = (0..<3).map { channel -> String in
                var components = [CGFloat](repeating: 0, count: 4); components[channel] = 1; components[3] = 1
                let converted = CGColor(colorSpace: source, components: components)!.converted(to: target, intent: .relativeColorimetric, options: nil)!.components!
                return "float3(\(Float(converted[0])), \(Float(converted[1])), \(Float(converted[2])))"
            }
            return "float3x3(\(columns.joined(separator: ", ")))"
        }
        return """
        float3 artflexLinearToP3(float3 c) { return \(matrix(from: srgb, to: p3)) * c; }
        float3 artflexP3ToLinear(float3 c) { return \(matrix(from: p3, to: srgb)) * c; }
        float3 artflexEncodeExtended(float3 c) {
            float3 v=abs(c); return sign(c)*select(1.055*pow(v,float3(1.0/2.4))-0.055, v*12.92, v<=0.0031308);
        }
        float3 artflexDecodeExtended(float3 c) {
            float3 v=abs(c); return sign(c)*select(pow((v+0.055)/1.055,float3(2.4)),v/12.92,v<=0.04045);
        }
        bool artflexIsWide(float3 c) { return any(c < 0.0) || any(c > 1.0); }
        float3 artflexEncodedToP3(float3 c) { return artflexEncodeExtended(artflexLinearToP3(artflexDecodeExtended(c))); }
        float3 artflexEncodedFromP3(float3 c) { return artflexEncodeExtended(artflexP3ToLinear(artflexDecodeExtended(c))); }
        """
    }()
}

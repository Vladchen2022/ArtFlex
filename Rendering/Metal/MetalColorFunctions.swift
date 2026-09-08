enum MetalColorFunctions {
    /// Matches LinearPremultipliedColor and the brush shader. Render targets expect linear RGB.
    static let source = """
    float3 artflexSrgbToLinear(float3 color) {
        return select(pow((color + 0.055) / 1.055, float3(2.4)), color / 12.92, color <= 0.04045);
    }
    """
}

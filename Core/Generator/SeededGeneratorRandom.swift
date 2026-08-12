import Foundation

/// SplitMix64-based deterministic source for generator sessions and synchronized canvases.
struct SeededGeneratorRandom: RandomNumberGenerator, Codable, Sendable, Equatable {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func nextUnitFloat() -> Float {
        let mantissa = UInt32(truncatingIfNeeded: next() >> 40)
        return Float(mantissa) / 16_777_216
    }

    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        return range.lowerBound + ((range.upperBound - range.lowerBound) * nextUnitFloat())
    }

    static func derivedSeed(baseSeed: UInt64, streamID: UInt64) -> UInt64 {
        var random = SeededGeneratorRandom(
            seed: baseSeed ^ (streamID &* 0xD2B7_4407_B1CE_6E93)
        )
        return random.next()
    }

    func forked(streamID: UInt64) -> SeededGeneratorRandom {
        SeededGeneratorRandom(seed: Self.derivedSeed(baseSeed: state, streamID: streamID))
    }
}

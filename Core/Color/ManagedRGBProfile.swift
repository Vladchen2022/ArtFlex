import Foundation

/// Output/proof profile. Canvas pixels always use canonical sRGB primaries; ICC conversion
/// happens at the image/display boundary, never by reinterpreting existing pixel values.
struct ManagedRGBProfile: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable { case sRGB, displayP3, icc }
    var kind: Kind
    var name: String
    var iccData: Data?
    static let sRGB = ManagedRGBProfile(kind: .sRGB, name: "sRGB")
    static let displayP3 = ManagedRGBProfile(kind: .displayP3, name: "Display P3")
}

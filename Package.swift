// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ArtFlex",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ArtFlex", targets: ["ArtFlex"])
    ],
    dependencies: [],
    targets: [
        .testTarget(
            name: "ArtFlexTests",
            dependencies: ["ArtFlex"],
            path: "Tests/ArtFlexTests"
        ),
        .executableTarget(
            name: "ArtFlex",
            dependencies: [],
            path: ".",
            exclude: [
                ".git",
                "AGENTS.md",
                "COLOR_PIXEL_SPEC.md",
                "CURRENT_STATUS.md",
                "MIGRATION_NOTES.md",
                "MVP_PLAN.md",
                "STAGE1_STATUS.md",
                "README.md",
                "Tests"
            ]
        )
    ]
)

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
    dependencies: [
        .package(
            url: "https://github.com/nicklockwood/Euclid.git",
            exact: "0.8.18"
        )
    ],
    targets: [
        .testTarget(
            name: "ArtFlexTests",
            dependencies: ["ArtFlex"],
            path: "Tests/ArtFlexTests"
        ),
        .executableTarget(
            name: "ArtFlex",
            dependencies: [
                .product(name: "Euclid", package: "Euclid")
            ],
            path: ".",
            exclude: [
                ".git",
                ".claude",
                "AGENTS.md",
                "CURRENT_STATUS.md",
                "DECISIONS.md",
                "Docs",
                "HANDOFF.md",
                "HANDOFF_TEXTURE_FILL_2026-07-13.md",
                "LICENSE",
                "Platform/macOS/Distribution",
                "README.md",
                "selection-trace.log",
                "Tests"
            ],
            resources: [
                .process("Platform/macOS/Resources")
            ]
        )
    ]
)

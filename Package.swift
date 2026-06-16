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
                ".claude",
                "AGENTS.md",
                "CURRENT_STATUS.md",
                "DECISIONS.md",
                "Docs",
                "HANDOFF.md",
                "LICENSE",
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

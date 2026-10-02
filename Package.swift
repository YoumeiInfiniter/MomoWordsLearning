// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MaimemoCompanion",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MaimemoAXCore", targets: ["MaimemoAXCore"]),
        .library(name: "WordMemoryCore", targets: ["WordMemoryCore"]),
        .executable(name: "maimemo-ax-probe", targets: ["MaimemoAXProbe"]),
        .executable(name: "word-memory-check", targets: ["WordMemoryCheck"]),
        .executable(name: "MaimemoCompanion", targets: ["MaimemoCompanionApp"])
    ],
    targets: [
        .target(
            name: "MaimemoAXCore"
        ),
        .target(
            name: "WordMemoryCore"
        ),
        .executableTarget(
            name: "MaimemoAXProbe",
            dependencies: ["MaimemoAXCore"]
        ),
        .executableTarget(
            name: "MaimemoCompanionApp",
            dependencies: ["MaimemoAXCore", "WordMemoryCore"]
        ),
        .executableTarget(
            name: "WordMemoryCheck",
            dependencies: ["WordMemoryCore"]
        )
    ]
)

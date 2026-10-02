// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MaimemoCompanion",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MaimemoAXCore", targets: ["MaimemoAXCore"]),
        .executable(name: "maimemo-ax-probe", targets: ["MaimemoAXProbe"]),
        .executable(name: "MaimemoCompanion", targets: ["MaimemoCompanionApp"])
    ],
    targets: [
        .target(
            name: "MaimemoAXCore"
        ),
        .executableTarget(
            name: "MaimemoAXProbe",
            dependencies: ["MaimemoAXCore"]
        ),
        .executableTarget(
            name: "MaimemoCompanionApp",
            dependencies: ["MaimemoAXCore"]
        )
    ]
)

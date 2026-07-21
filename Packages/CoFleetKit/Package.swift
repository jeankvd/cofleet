// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoFleetKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "CoFleetCore", targets: ["CoFleetCore"]),
        .library(name: "CoFleetTransport", targets: ["CoFleetTransport"]),
        .library(name: "CoFleetCodex", targets: ["CoFleetCodex"]),
        .library(name: "CoFleetUI", targets: ["CoFleetUI"]),
    ],
    targets: [
        .target(name: "CoFleetCore"),
        .target(name: "CoFleetTransport", dependencies: ["CoFleetCore"]),
        .target(
            name: "CoFleetCodex",
            dependencies: ["CoFleetCore", "CoFleetTransport"]
        ),
        .target(
            name: "CoFleetUI",
            dependencies: ["CoFleetCore", "CoFleetTransport", "CoFleetCodex"]
        ),
        .testTarget(
            name: "CoFleetKitTests",
            dependencies: ["CoFleetCore", "CoFleetTransport", "CoFleetCodex", "CoFleetUI"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

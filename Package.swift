// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "Orbit", targets: ["Eclick"])
    ],
    targets: [
        .executableTarget(
            name: "Eclick",
            path: "Sources/Eclick"
        )
    ]
)

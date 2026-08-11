// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Eclick",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "Eclick", targets: ["Eclick"])
    ],
    targets: [
        .executableTarget(
            name: "Eclick",
            path: "Sources/Eclick"
        )
    ]
)

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LiveNotesCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LiveNotesCore", targets: ["LiveNotesCore"])
    ],
    targets: [
        .target(name: "LiveNotesCore"),
        .testTarget(
            name: "LiveNotesCoreTests",
            dependencies: ["LiveNotesCore"]
        )
    ]
)

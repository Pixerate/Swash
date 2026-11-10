// swift-tools-version: 6.0
// Open-source stub for PixerateStickers. In official App Store builds, CI replaces this package
// directory with a checkout of https://github.com/Pixerate/stickers.git.
import PackageDescription

let package = Package(
    name: "PixerateStickers",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "PixerateStickers",
            targets: ["PixerateStickers"]
        ),
    ],
    targets: [
        .target(
            name: "PixerateStickers",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PixerateStickersTests",
            dependencies: ["PixerateStickers"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

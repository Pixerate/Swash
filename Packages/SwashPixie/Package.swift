// swift-tools-version: 6.0
// Open-source stub for SwashPixie: this build has no Pixie, so her chat stays hidden
// (`SwashPixie.isAvailable` is false). Official releases replace this directory with
// `Packages/SwashPixieFull`, which uses the private Pixerate/pixie package (docs/RELEASING.md).
import PackageDescription

let package = Package(
    name: "SwashPixie",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SwashPixie", targets: ["SwashPixie"])],
    dependencies: [
        .package(url: "https://github.com/Pixerate/editor", .upToNextMinor(from: "0.82.0")),
        .package(url: "https://github.com/Pixerate/PixerateAccount", .upToNextMinor(from: "0.3.0")),
    ],
    targets: [
        .target(
            name: "SwashPixie",
            dependencies: [
                .product(name: "PixerateCore", package: "editor"),
                .product(name: "PixerateStore", package: "PixerateAccount"),
            ]
        ),
    ]
)

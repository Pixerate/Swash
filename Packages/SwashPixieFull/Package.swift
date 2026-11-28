// swift-tools-version: 6.0
// SwashPixie with Pixie: her chat on Swash documents, on the private Pixerate/pixie package.
// Official releases copy this over `Packages/SwashPixie` (the open-source stub) and fetch
// Pixerate/pixie with `PIXERATE_PACKAGES_TOKEN` (docs/RELEASING.md). Swash itself only ever
// references `Packages/SwashPixie`, so builds without access never try to fetch it.
import PackageDescription

let package = Package(
    name: "SwashPixie",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SwashPixie", targets: ["SwashPixie"])],
    dependencies: [
        .package(url: "https://github.com/Pixerate/editor", .upToNextMinor(from: "0.82.0")),
        .package(url: "https://github.com/Pixerate/PixerateAccount", .upToNextMinor(from: "0.3.0")),
        .package(url: "https://github.com/Pixerate/pixie.git", .upToNextMinor(from: "0.9.0")),
    ],
    targets: [
        .target(
            name: "SwashPixie",
            dependencies: [
                .product(name: "PixerateCore", package: "editor"),
                .product(name: "PixerateStore", package: "PixerateAccount"),
                .product(name: "PixieKit", package: "pixie"),
                .product(name: "PixieUI", package: "pixie"),
            ]
        ),
    ]
)

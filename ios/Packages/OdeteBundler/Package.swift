// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteBundler",
    platforms: [.iOS(.v26)],
    products: [.library(name: "OdeteBundler", targets: ["OdeteBundler"])],
    dependencies: [.package(path: "../OdeteCore"), .package(path: "../OdeteRuntime")],
    targets: [
        .target(
            name: "OdeteBundler",
            dependencies: [
                .product(name: "OdeteCore", package: "OdeteCore"),
                .product(name: "OdeteRuntime", package: "OdeteRuntime"),
            ],
            resources: [.copy("Resources/esbuild"), .copy("Resources/js")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OdeteBundlerTests", dependencies: ["OdeteBundler"]),
    ]
)

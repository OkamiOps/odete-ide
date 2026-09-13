// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteApp",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OdeteApp", targets: ["OdeteApp"]),
    ],
    dependencies: [
        .package(path: "../OdeteCore"),
        .package(path: "../OdeteFiles"),
        .package(path: "../OdeteEditor"),
        .package(path: "../OdeteUI"),
    ],
    targets: [
        .target(
            name: "OdeteApp",
            dependencies: [
                .product(name: "OdeteCore", package: "OdeteCore"),
                .product(name: "OdeteFiles", package: "OdeteFiles"),
                .product(name: "OdeteEditor", package: "OdeteEditor"),
                .product(name: "OdeteUI", package: "OdeteUI"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OdeteAppTests", dependencies: ["OdeteApp"]),
    ]
)

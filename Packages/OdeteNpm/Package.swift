// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteNpm",
    platforms: [.iOS(.v26)],
    products: [.library(name: "OdeteNpm", targets: ["OdeteNpm"])],
    dependencies: [
        .package(path: "../OdeteI18n"), .package(path: "../OdeteCore"),
    ],
    targets: [
        .target(
            name: "OdeteNpm",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"), .product(name: "OdeteCore", package: "OdeteCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OdeteNpmTests", dependencies: ["OdeteNpm"]),
    ]
)

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteNpm",
    platforms: [.iOS(.v26)],
    products: [.library(name: "OdeteNpm", targets: ["OdeteNpm"])],
    dependencies: [
        .package(path: "../OdeteI18n"), .package(path: "../OdeteCore"),
        // Onde mora o node_modules (pasta ou link para node_modules.nosync no iCloud).
        .package(path: "../OdeteFiles"),
    ],
    targets: [
        .target(
            name: "OdeteNpm",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"), .product(name: "OdeteCore", package: "OdeteCore"),
                .product(name: "OdeteFiles", package: "OdeteFiles"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OdeteNpmTests",
            dependencies: [
                "OdeteNpm", .product(name: "OdeteFiles", package: "OdeteFiles"),
                .product(name: "OdeteI18n", package: "OdeteI18n"),
            ]
        ),
    ]
)

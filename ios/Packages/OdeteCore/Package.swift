// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteCore",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OdeteCore", targets: ["OdeteCore"]),
    ],
    dependencies: [
        .package(path: "../OdeteI18n"),
    ],
    targets: [
        .target(
            name: "OdeteCore",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OdeteCoreTests",
            dependencies: ["OdeteCore", .product(name: "OdeteI18n", package: "OdeteI18n")]
        ),
    ]
)

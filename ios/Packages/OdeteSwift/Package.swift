// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteSwift",
    platforms: [.iOS(.v26)],
    products: [.library(name: "OdeteSwift", targets: ["OdeteSwift"])],
    dependencies: [
        .package(path: "../OdeteI18n"), .package(path: "../OdeteCore"),
    ],
    targets: [
        .target(
            name: "OdeteSwift",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"), .product(name: "OdeteCore", package: "OdeteCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OdeteSwiftTests",
            dependencies: ["OdeteSwift", .product(name: "OdeteI18n", package: "OdeteI18n")]
        ),
    ]
)

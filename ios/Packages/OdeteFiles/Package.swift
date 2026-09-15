// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteFiles",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OdeteFiles", targets: ["OdeteFiles"]),
    ],
    dependencies: [
        .package(path: "../OdeteI18n"),
        .package(path: "../OdeteCore"),
    ],
    targets: [
        .target(
            name: "OdeteFiles",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"),
                .product(name: "OdeteCore", package: "OdeteCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OdeteFilesTests", dependencies: ["OdeteFiles"]),
    ]
)

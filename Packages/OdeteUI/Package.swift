// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteUI",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OdeteUI", targets: ["OdeteUI"]),
    ],
    dependencies: [
        .package(path: "../OdeteI18n"),
        .package(path: "../OdeteCore"),
        .package(path: "../OdeteEditor"),
        .package(path: "../OdeteFiles"),
    ],
    targets: [
        .target(
            name: "OdeteUI",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"),
                .product(name: "OdeteCore", package: "OdeteCore"),
                .product(name: "OdeteEditor", package: "OdeteEditor"),
                .product(name: "OdeteFiles", package: "OdeteFiles"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OdeteUITests", dependencies: ["OdeteUI"]),
    ]
)

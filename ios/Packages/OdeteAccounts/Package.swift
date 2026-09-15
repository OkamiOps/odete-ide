// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteAccounts",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OdeteAccounts", targets: ["OdeteAccounts"]),
    ],
    dependencies: [
        .package(path: "../OdeteI18n"),
        .package(path: "../OdeteCore"),
    ],
    targets: [
        .target(
            name: "OdeteAccounts",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"), .product(name: "OdeteCore", package: "OdeteCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OdeteAccountsTests", dependencies: ["OdeteAccounts"]),
    ]
)

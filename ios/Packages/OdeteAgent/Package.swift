// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteAgent",
    platforms: [.iOS(.v26)],
    products: [.library(name: "OdeteAgent", targets: ["OdeteAgent"])],
    dependencies: [
        .package(path: "../OdeteI18n"),
        .package(path: "../OdeteCore"), .package(path: "../OdeteAccounts"), .package(path: "../OdeteGit"),
    ],
    targets: [
        .target(
            name: "OdeteAgent",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"),
                .product(name: "OdeteCore", package: "OdeteCore"), .product(
                    name: "OdeteAccounts",
                    package: "OdeteAccounts"
                ),
                .product(name: "OdeteGit", package: "OdeteGit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OdeteAgentTests", dependencies: ["OdeteAgent"], resources: [.copy("Fixtures")]),
    ]
)

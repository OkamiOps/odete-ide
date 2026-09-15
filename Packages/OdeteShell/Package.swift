// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteShell",
    platforms: [.iOS(.v26)],
    products: [.library(name: "OdeteShell", targets: ["OdeteShell"])],
    dependencies: [
        .package(path: "../OdeteI18n"),
        .package(path: "../OdeteCore"), .package(path: "../OdeteGit"), .package(path: "../OdeteNpm"),
        .package(path: "../OdeteRuntime"), .package(path: "../OdeteBundler"),
    ],
    targets: [
        .target(
            name: "OdeteShell",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"),
                .product(name: "OdeteCore", package: "OdeteCore"), .product(name: "OdeteGit", package: "OdeteGit"),
                .product(name: "OdeteNpm", package: "OdeteNpm"), .product(
                    name: "OdeteRuntime",
                    package: "OdeteRuntime"
                ),
                .product(name: "OdeteBundler", package: "OdeteBundler"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OdeteShellTests",
            dependencies: ["OdeteShell", .product(name: "OdeteI18n", package: "OdeteI18n")]
        ),
    ]
)

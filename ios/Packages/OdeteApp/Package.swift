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
        .package(path: "../OdeteGit"),
        .package(path: "../OdeteAccounts"),
        .package(path: "../OdeteShell"),
        .package(path: "../OdetePreview"),
        .package(path: "../OdeteAgent"),
        .package(path: "../OdeteSwift"),
    ],
    targets: [
        .target(
            name: "OdeteApp",
            dependencies: [
                .product(name: "OdeteCore", package: "OdeteCore"),
                .product(name: "OdeteFiles", package: "OdeteFiles"),
                .product(name: "OdeteEditor", package: "OdeteEditor"),
                .product(name: "OdeteUI", package: "OdeteUI"),
                .product(name: "OdeteGit", package: "OdeteGit"),
                .product(name: "OdeteAccounts", package: "OdeteAccounts"),
                .product(name: "OdeteShell", package: "OdeteShell"),
                .product(name: "OdetePreview", package: "OdetePreview"),
                .product(name: "OdeteAgent", package: "OdeteAgent"),
                .product(name: "OdeteSwift", package: "OdeteSwift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OdeteAppTests", dependencies: ["OdeteApp"]),
    ]
)

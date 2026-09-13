// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteEditor",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OdeteEditor", targets: ["OdeteEditor"]),
    ],
    dependencies: [
        .package(path: "../OdeteCore"),
        .package(url: "https://github.com/simonbs/Runestone.git", from: "0.5.2"),
    ],
    targets: [
        .target(
            name: "OdeteEditor",
            dependencies: [
                .product(name: "OdeteCore", package: "OdeteCore"),
                .product(name: "Runestone", package: "Runestone"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

    ]
)

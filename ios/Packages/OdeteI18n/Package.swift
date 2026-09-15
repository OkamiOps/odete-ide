// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteI18n",
    defaultLocalization: "pt-BR",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OdeteI18n", targets: ["OdeteI18n"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "OdeteI18n",
            dependencies: [
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OdeteI18nTests", dependencies: ["OdeteI18n"]),
    ]
)

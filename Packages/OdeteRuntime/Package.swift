// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteRuntime",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OdeteRuntime", targets: ["OdeteRuntime"]),
    ],
    dependencies: [
        .package(path: "../OdeteI18n"),
        .package(path: "../OdeteCore"),
    ],
    targets: [
        .target(
            name: "OdeteRuntime",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"), .product(name: "OdeteCore", package: "OdeteCore"),
            ],
            resources: [.copy("Resources/node")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Network")]
        ),
        .testTarget(name: "OdeteRuntimeTests", dependencies: ["OdeteRuntime"]),
    ]
)

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteCore",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OdeteCore", targets: ["OdeteCore"]),
    ],
    dependencies: [

    ],
    targets: [
        .target(
            name: "OdeteCore",
            dependencies: [

            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OdeteCoreTests", dependencies: ["OdeteCore"]),
    ]
)
